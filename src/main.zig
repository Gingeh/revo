const std = @import("std");
const Allocator = std.mem.Allocator;
const build_opts = @import("build_options");
const lsp_enabled = build_opts.lsp_enabled;

const revo = @import("revo");
const docs = revo.lang.docs;
const Artifact = revo.lang.Artifact;
const VM = revo.VM;
const pretty = revo.pretty;

const repl = @import("repl.zig");

test {
    _ = std.testing.refAllDecls(repl);
}

const USAGE =
    \\usage: revo [options] [script [args...]]
    \\       revo <command> [options]
    \\
    \\options:
    \\  -e code          run code
    \\  -i               enter repl after executing
    \\  -d,-D            output the last evaluated value of the program in display/debug mode
    \\  --test           run with test blocks
    \\  -h, --help       show this help message
    \\  --version        show version
    \\
    \\commands:
    \\  compile          compile script to bytecode instead of running
    \\                   runs only the comp/proc blocks
    \\  repl             start repl (default with no args)
    \\
++ (if (lsp_enabled)
    \\  lsp              start the lsp
    \\
else
    "") ++
    \\  dis              show bytecode disassembly instead of running
    \\  bench[n]         run with performance counters ([n] iterations, 1 if not specified)
    \\  docs             extract doc comments from a file, dir, or the pwd workspace
    \\                   --html    render as docgen markdown reference format
    \\                   --splice  splice output into markdown piped on stdin
    \\                             (implied by --html with a target arg)
    \\
    \\if the first argument is a command that exists, it gets ran;
    \\otherwise, it's treated as a script path
    \\
    \\examples:
    \\  revo                              start repl
    \\  revo script.rv                    run script
    \\  revo compile script.rv            compile script
    \\  revo compile script.rv out.rvo    compile script with custom output path
    \\  revo -e "1 + 2"                   run inline code
    \\  revo -e "1 + 2" -i                run inline code and enter REPL
    \\  revo bench script.rv              run with performance counters
    \\  revo dis script.rv                show bytecode disassembly
    \\  revo docs script.rv               print extracted docs without running code
    \\  revo docs --html src/std/iface    render the stdlib reference as markdown
    \\  revo docs --html src/std/iface < std.md > std.new   splice into a doc page
    \\
++ (if (lsp_enabled)
    \\  revo lsp                          start the language server
    \\
else
    "") ++
    \\  revo repl                         start repl explicitly
    \\  revo lsp.rv                       run a script literally named lsp.rv
;

const ExecutionMode = enum { run, repl, bench, disassemble, compile, docs, docs_html, lsp };

const Config = struct {
    mode: ExecutionMode = .run,
    inline_code: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    interactive: bool = false,
    test_mode: bool = false,
    bench_iters: u32 = 1,
    echo_last: ?revo.Data.RenderMode = null,
    force_splice: bool = false,
    argv: []const [:0]const u8 = &.{},
};

pub fn main(provided_init: std.process.Init) void {
    var init = provided_init;
    pretty.supports_color = pretty.isColorSupported(init.environ_map, init.io);

    if (build_opts.mimalloc) init.gpa = @import("mimalloc").mim_allocator;

    runMain(init) catch |x| switch (x) {
        error.VmInitError,
        error.InsufficientArgs,
        error.InvalidArgs,
        error.UnknownCommand,
        error.CompilationError,
        error.FileError,
        => std.process.exit(1),
        error.HelpRequested,
        error.VersionRequested,
        => {},
        else => |err| {
            var stderr_buf: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);
            pretty.printError(&stderr.interface, "{s}", .{@errorName(err)}) catch return;
            std.process.exit(1);
        },
    };
}

fn handleSource(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    name: []const u8,
    source: []const u8,
    config: Config,
) !void {
    switch (config.mode) {
        .run => try runSource(init, gpa, name, source, config),
        .bench => try benchSource(init, gpa, name, source, config),
        .compile => try compileToBytecode(init, gpa, arena, name, source, config),
        .docs, .docs_html => unreachable,
        .disassemble => {
            var vm = try initVM(init, gpa, config.argv);
            defer vm.deinit();
            const artifact = try compileSource(init, &vm, gpa, name, source, config.test_mode);
            defer gpa.free(artifact.instructions);
            defer gpa.free(artifact.spans);
            try revo.vm.debug.printDisassembly(&vm, artifact, source);
        },
        .repl, .lsp => unreachable,
    }
}

fn runMain(init: std.process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        const stdin_file = std.Io.File.stdin();
        if (!try stdin_file.isTty(init.io)) {
            const source = std.Io.Dir.cwd().readFileAlloc(
                init.io,
                "/dev/stdin",
                arena,
                std.Io.Limit.unlimited,
            ) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };

            const cfg: Config = .{};
            var vm = try initVM(init, init.gpa, &.{args[0]});
            defer vm.deinit();
            try runSource(init, init.gpa, "<stdin>", source, cfg);
            return;
        }

        var vm = try initVM(init, init.gpa, &.{args[0]});
        defer vm.deinit();
        try repl.run(&vm, init.gpa, init);
        return;
    }

    const config = try parseArgs(init, args);

    if (config.mode == .repl) {
        var vm = try initVM(init, init.gpa, config.argv);
        defer vm.deinit();
        return try repl.run(&vm, init.gpa, init);
    }

    if (config.mode == .lsp) {
        var project = revo.lang.Project.detectFromCwd(init.io, init.gpa);
        defer project.deinit(init.gpa);
        return try @import("lsp_main").runLsp(init.gpa, init.io, project.mode, project.root);
    }

    // docs modes always run the docgen pipeline: extract from a file, a dir
    // of sources, the pwd workspace, or a piped source; `--docs-html` splices
    // into piped markdown when stdin isn't a tty
    if (config.mode == .docs or config.mode == .docs_html) {
        try runDocs(init, init.gpa, arena, config);
        return;
    }

    // if script path `-` then explicit stdin;
    // else if no script path and stdin is pipe, read stdin then run
    if (config.script_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            const source = std.Io.Dir.cwd().readFileAlloc(
                init.io,
                "/dev/stdin",
                arena,
                std.Io.Limit.unlimited,
            ) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };
            if (std.mem.startsWith(u8, source, &revo.bytecode.MAGIC)) {
                try runBytecode(init, init.gpa, "<stdin>", source, config);
            } else {
                try handleSource(init, init.gpa, init.arena.allocator(), "<stdin>", source, config);
            }
            if (config.inline_code) |code| try runInlineCode(init, init.gpa, code, config);
            if (!config.interactive) return;
        } else {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, std.Io.Limit.unlimited) catch |err| {
                printError(init, "{s} '{s}'", .{ @errorName(err), path });
                return error.FileError;
            };

            if (std.mem.endsWith(u8, path, ".rvo")) {
                switch (config.mode) {
                    .run => try runBytecode(init, init.gpa, path, source, config),
                    .bench => try benchBytecode(init, init.gpa, path, source, config),
                    .disassemble => {
                        var vm = try initVM(init, init.gpa, config.argv);
                        defer vm.deinit();
                        var deserialized = revo.bytecode.deserialize(&vm, source, init.gpa) catch |err| {
                            printError(init, "deserializing bytecode - {}", .{err});
                            return error.CompilationError;
                        };
                        defer deserialized.deinit();
                        try revo.vm.debug.printDisassembly(&vm, .{
                            .instructions = deserialized.instructions,
                            .spans = deserialized.spans,
                        }, "");
                    },
                    .compile => {
                        printError(init, "cannot compile bytecode files", .{});
                        return error.InvalidArgs;
                    },
                    .docs, .docs_html => {
                        printError(init, "cannot extract docs from bytecode files", .{});
                        return error.InvalidArgs;
                    },
                    .repl, .lsp => unreachable,
                }
            } else {
                try handleSource(init, init.gpa, arena, path, source, config);
            }
            if (!config.interactive) return;
        }
    } else {
        const stdin_file = std.Io.File.stdin();
        if (!try stdin_file.isTty(init.io)) {
            const source = std.Io.Dir.cwd().readFileAlloc(
                init.io,
                "/dev/stdin",
                arena,
                std.Io.Limit.unlimited,
            ) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };
            if (std.mem.startsWith(u8, source, &revo.bytecode.MAGIC)) {
                try runBytecode(init, init.gpa, "<stdin>", source, config);
            } else {
                try handleSource(init, init.gpa, init.arena.allocator(), "<stdin>", source, config);
            }
            if (!config.interactive and config.inline_code == null) return;
        }
    }

    if (config.inline_code) |code| {
        try runInlineCode(init, init.gpa, code, config);
        if (!config.interactive and config.script_path == null) return;
    }

    var vm = try initVM(init, init.gpa, config.argv);
    defer vm.deinit();
    try repl.run(&vm, init.gpa, init);
}

fn printError(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printError(&buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn printSuccess(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printSuccess(&buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn initVM(init: std.process.Init, gpa: Allocator, argv: []const [:0]const u8) !VM {
    return VM.init(.{ .alloc = gpa, .io = init.io, .argv = argv, .diag_alloc = gpa }) catch |err| {
        printError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
}

fn compileSource(
    init: std.process.Init,
    vm: *VM,
    gpa: Allocator,
    source_name: []const u8,
    source_text: []const u8,
    test_mode: bool,
) !Artifact {
    var ws = try revo.lang.Workspace.initWithVm(vm, gpa);
    defer ws.deinit();

    var project = revo.lang.Project.detect(source_name, init.io, gpa);
    defer project.deinit(gpa);

    if (project.mode == .project and project.root.len > 0)
        vm.project_root = try gpa.dupe(u8, project.root);

    const file_id = try project.open(&ws, source_name, source_text);
    var analysis = ws.analyzeDetailed(gpa, file_id, .{ .test_mode = test_mode, .mode = project.mode }) catch |err| {
        printError(init, "compilation - {}", .{err});
        return error.CompilationError;
    };
    defer analysis.deinit(gpa);

    if (analysis.diagnostics) |lang_err| {
        revo.printBuildError(gpa, .{ .name = source_name, .text = source_text }, lang_err);
        analysis.diagnostics = null;
        vm.runtime.resetDiagArena();
        return error.CompilationError;
    }

    const artifact = analysis.artifact.?;
    analysis.artifact = null;
    return artifact;
}

fn printResult(vm: *VM, mode: revo.Data.RenderMode) !void {
    var res = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer res.deinit();
    vm.mainResult().write(&res.writer, vm, mode) catch return;
    std.debug.print("{s}\n", .{res.written()});
}

fn runCompiledArtifact(
    _: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    artifact: Artifact,
    source: []const u8,
    echo_last: ?revo.Data.RenderMode,
) !void {
    try vm.setProgramDebugInfo(artifact.spans, source, name);

    const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) |mode| try printResult(vm, mode),
        .err => |failure| {
            revo.printEvalError(gpa, source, failure);
            vm.runtime.resetDiagArena();
        },
    }
}

/// cli options only appear before the script name; the first bare word is
/// either a command (`compile`, `dis`, `docs`, ...) or the script path -
/// everything past it flows into the runtime's argv untouched
fn parseArgs(init: std.process.Init, args: []const [:0]const u8) !Config {
    var config: Config = .{};
    var i: usize = 1;

    var argv: std.ArrayList([:0]const u8) = .empty;

    // leading command word
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) blk: {
        const cmd = args[i];
        if (std.mem.eql(u8, cmd, "compile")) {
            config.mode = .compile;
        } else if (std.mem.eql(u8, cmd, "repl")) {
            config.mode = .repl;
        } else if (if (lsp_enabled) std.mem.eql(u8, cmd, "lsp") else false) {
            config.mode = .lsp;
        } else if (std.mem.eql(u8, cmd, "dis")) {
            config.mode = .disassemble;
        } else if (std.mem.eql(u8, cmd, "docs")) {
            config.mode = .docs;
        } else if (std.mem.startsWith(u8, cmd, "bench")) {
            // bench / bench[n]; anything else falls through to script path
            const n = cmd[5..];
            const iters = if (n.len == 0) 1 else std.fmt.parseUnsigned(u32, n, 10) catch break :blk;
            config.mode = .bench;
            config.bench_iters = iters;
        } else break :blk;

        i += 1;
    }

    // options, never parsed past the script name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) break;
        if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) {
                printError(init, "-e requires an argument", .{});
                return error.InsufficientArgs;
            }
            try argv.append(init.arena.allocator(), args[0]);
            config.inline_code = args[i];
        } else if (std.mem.eql(u8, arg, "-i")) {
            config.interactive = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            config.echo_last = .display;
        } else if (std.mem.eql(u8, arg, "-D")) {
            config.echo_last = .debug;
        } else if (std.mem.eql(u8, arg, "--test")) {
            config.test_mode = true;
        } else if (std.mem.eql(u8, arg, "--html")) {
            if (config.mode == .docs) config.mode = .docs_html;
        } else if (std.mem.eql(u8, arg, "--splice")) {
            config.force_splice = true;
        } else if (std.mem.eql(u8, arg, "--dis")) {
            config.mode = .disassemble;
        } else if (std.mem.eql(u8, arg, "--docs")) {
            config.mode = .docs;
        } else if (std.mem.eql(u8, arg, "--docs-html")) {
            config.mode = .docs_html;
        } else if (std.mem.eql(u8, arg, "--docs-splice")) {
            config.force_splice = true;
        } else if (std.mem.startsWith(u8, arg, "--bench")) {
            // legacy flag form of the bench command
            config.mode = .bench;
            if (arg.len > 7) {
                config.bench_iters = std.fmt.parseUnsigned(u32, arg[7..], 10) catch |err| {
                    printError(init, "invalid bench iteration count '{s}' - {}", .{ arg[7..], err });
                    return error.InvalidArgs;
                };
            }
        } else if (std.mem.eql(u8, arg, "-b")) {
            // legacy flag form of the compile command
            config.mode = .compile;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                printError(init, "-o requires an argument", .{});
                return error.InsufficientArgs;
            }
            config.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{USAGE});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("revo " ++ @import("build_options").version ++ "\n", .{});
            return error.VersionRequested;
        } else if (if (lsp_enabled) std.mem.eql(u8, arg, "--lsp") else false) {
            config.mode = .lsp;
        } else {
            printError(init, "unknown option '{s}'", .{arg});
            std.debug.print("{s}\n", .{USAGE});
            return error.UnknownCommand;
        }
    }

    // first positional is the script; the rest is runtime argv.
    // compile takes one extra positional - the output path
    while (i < args.len) : (i += 1) {
        if (config.script_path == null and config.inline_code == null) {
            config.script_path = args[i];
            try argv.append(init.arena.allocator(), args[i]);
        } else if (config.mode == .compile and config.output_path == null and
            !std.mem.startsWith(u8, args[i], "-"))
        {
            config.output_path = args[i];
        } else {
            try argv.append(init.arena.allocator(), args[i]);
        }
    }

    config.argv = try argv.toOwnedSlice(init.arena.allocator());
    return config;
}

/// docs mode against a source file, a dir of sources, or the pwd workspace;
/// `--docs-html` splices into a piped markdown page when stdin isn't a tty.
/// splicing needs a target arg or an explicit `--docs-splice`; plain piped
/// stdin with no target means "extract from stdin", so `--docs-html < file.rv`
/// renders the body instead of erroring on missing markers.
/// a parse failure in an explicit target is fatal, in a walked workspace
/// it's a warning - keep going, one bad file shouldn't kill the page
fn runDocs(init: std.process.Init, gpa: Allocator, arena: Allocator, config: Config) !void {
    const html = config.mode == .docs_html;
    const stdin_tty = try std.Io.File.stdin().isTty(init.io);
    const splice = html and !stdin_tty and
        (config.force_splice or config.script_path != null);

    var owned = std.ArrayList([]docs.FnSpec).empty;
    defer owned.deinit(arena);
    var flat = std.ArrayList(*const docs.FnSpec).empty;
    defer flat.deinit(arena);
    var module_doc: []const u8 = "";

    const target: []const u8 = blk: {
        if (config.script_path) |path| {
            if (isDir(init, path)) {
                try collectAll(init, gpa, arena, path, &owned, &flat);
            } else {
                module_doc = try addDocsFromPath(init, gpa, arena, path, &owned, &flat);
            }
            break :blk path;
        } else if (splice or stdin_tty) {
            var project = revo.lang.Project.detectFromCwd(init.io, gpa);
            defer project.deinit(gpa);
            const root_dir: []const u8 = if (project.root.len > 0) project.root else ".";
            const t = try arena.dupe(u8, root_dir);
            try collectAll(init, gpa, arena, t, &owned, &flat);
            break :blk t;
        } else {
            // `--docs-html`/`--docs` piped a revo source on stdin
            module_doc = try addDocsFromPath(init, gpa, arena, "/dev/stdin", &owned, &flat);
            break :blk "<stdin>";
        }
    };

    try emitDocs(init, gpa, arena, target, flat.items, module_doc, html, splice);
    for (owned.items) |s| docs.freeSpecs(gpa, s);
}

/// extract docs from every `*.rv` in a dir; parse errors warn and skip
fn collectAll(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    dir: []const u8,
    owned: *std.ArrayList([]docs.FnSpec),
    flat: *std.ArrayList(*const docs.FnSpec),
) !void {
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(arena);
    try collectSourceFiles(init, arena, dir, &files);
    std.mem.sort([]const u8, files.items, {}, docs.lessStr);
    for (files.items) |f| {
        const source = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            f,
            arena,
            std.Io.Limit.unlimited,
        ) catch |err| {
            printError(init, "reading {s} - {}", .{ f, err });
            return error.FileError;
        };
        _ = addDocsFromSource(gpa, arena, source, owned, flat) catch |err| switch (err) {
            error.IfaceParseFailed,
            error.IfaceParamNotTyped,
            error.IfaceBadBindingTarget,
            error.IfaceDeclNotAFunction,
            error.BadCoreKey,
            error.BadDoc,
            => std.debug.print("skipping {s}: {s}\n", .{ f, @errorName(err) }),
            else => |e| return e,
        };
    }
}

/// read one source and extract its docs; a parse failure is fatal.
/// returns the module's own doc, if the file carries one
fn addDocsFromPath(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    path: []const u8,
    owned: *std.ArrayList([]docs.FnSpec),
    flat: *std.ArrayList(*const docs.FnSpec),
) ![]const u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        arena,
        std.Io.Limit.unlimited,
    ) catch |err| {
        printError(init, "reading {s} - {}", .{ path, err });
        return error.FileError;
    };
    return addDocsFromSource(gpa, arena, source, owned, flat) catch |err| switch (err) {
        error.IfaceParseFailed => {
            printError(init, "parse error while extracting docs", .{});
            return error.CompilationError;
        },
        else => |e| return e,
    };
}

/// extract docs from one in-memory source; returns the module doc, which
/// borrows from `source`
fn addDocsFromSource(
    gpa: Allocator,
    arena: Allocator,
    source: []const u8,
    owned: *std.ArrayList([]docs.FnSpec),
    flat: *std.ArrayList(*const docs.FnSpec),
) ![]const u8 {
    const extracted = try docs.docsExtract(gpa, source);
    try owned.append(arena, extracted.specs);
    for (extracted.specs) |*s| try flat.append(arena, s);
    return extracted.module_doc;
}

/// recursive walk for `*.rv` sources, skipping hidden dirs and build dirs
fn collectSourceFiles(init: std.process.Init, arena: Allocator, dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    const open_dir = std.Io.Dir.cwd().openDir(init.io, dir, .{ .iterate = true }) catch |err| {
        printError(init, "opening {s} - {}", .{ dir, err });
        return error.FileError;
    };
    defer open_dir.close(init.io);
    var it = open_dir.iterate();
    while (try it.next(init.io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                if (std.mem.eql(u8, entry.name, "zig-out")) continue;
                const sub = try std.fs.path.join(arena, &.{ dir, entry.name });
                try collectSourceFiles(init, arena, sub, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".rv")) continue;
                try out.append(arena, try std.fs.path.join(arena, &.{ dir, entry.name }));
            },
            else => {},
        }
    }
}

fn isDir(init: std.process.Init, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(init.io, path, .{}) catch return false;
    d.close(init.io);
    return true;
}

/// render the extracted specs - plain listing or docgen markdown - and
/// write to stdout, splicing into piped markdown when `splice`
fn emitDocs(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    target: []const u8,
    flat: []*const docs.FnSpec,
    module_doc: []const u8,
    html: bool,
    splice: bool,
) !void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    if (html) {
        try docs.renderMarkdown(gpa, &buf.writer, flat, module_doc);
    } else {
        try renderPlain(&buf.writer, target, flat, module_doc);
    }

    const body = std.mem.trim(u8, buf.written(), "\n");

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    if (splice) {
        const old = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            "/dev/stdin",
            arena,
            std.Io.Limit.unlimited,
        );
        const spliced = try docs.spliceMarkdown(arena, old, body);
        try out.interface.writeAll(spliced);
    } else {
        try out.interface.writeAll(body);
        try out.interface.writeAll("\n");
    }
    try out.flush();
}

/// plain listing: name/arity plus the doc text, documented specs only
fn renderPlain(
    w: *std.Io.Writer,
    target: []const u8,
    specs: []*const docs.FnSpec,
    module_doc: []const u8,
) !void {
    try w.print("# docs for {s}\n", .{target});
    if (module_doc.len > 0) try w.print("\n{s}\n", .{module_doc});
    var count: usize = 0;
    for (specs) |s| {
        if (s.doc.len == 0 and s.fields.len == 0) continue;
        count += 1;
        if (s.fields.len > 0) {
            try w.print("\n- struct {s}\n{s}\n", .{ s.name, s.doc });
            for (s.fields) |fl| {
                try w.print("  - `{s}", .{fl.name});
                if (fl.type_text.len > 0) try w.print(": {s}", .{fl.type_text});
                if (fl.doc.len > 0) try w.print("` - {s}", .{fl.doc}) else try w.writeAll("`");
                try w.writeAll("\n");
            }
        } else if (s.is_value)
            try w.print("\n- {s}\n{s}\n", .{ s.name, s.doc })
        else
            try w.print("\n- {s}/{d}\n{s}\n", .{ s.name, s.params.len, s.doc });
    }
    if (count == 0) try w.writeAll("\n(no doc comments found)\n");
}

fn runInlineCode(init: std.process.Init, gpa: Allocator, code: []const u8, config: Config) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, "<inline>", code, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try runCompiledArtifact(init, gpa, &vm, "<inline>", artifact, code, config.echo_last);
}

fn runSource(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try vm.setProgramDebugInfo(artifact.spans, source, path);

    // std.debug.print("running\n", .{});
    try runCompiledArtifact(init, gpa, &vm, path, artifact, source, config.echo_last);
}

fn runBytecode(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    bytecode_data: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    var deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer deserialized.deinit();

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try runCompiledArtifact(
        init,
        gpa,
        &vm,
        path,
        .{ .spans = deserialized.spans, .instructions = deserialized.instructions },
        "",
        config.echo_last,
    );
}

fn benchArtifact(
    init: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    artifact: Artifact,
    source: []const u8,
    iters: u32,
    echo_last: ?revo.Data.RenderMode,
) !void {
    var times = try std.ArrayList(std.Io.Duration).initCapacity(gpa, iters);
    defer times.deinit(gpa);

    var last_result: ?revo.EvalResult = null;

    for (0..iters) |_| {
        const t_start = std.Io.Timestamp.now(init.io, .cpu_process);
        const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
        const t_end = std.Io.Timestamp.now(init.io, .cpu_process);
        times.appendAssumeCapacity(t_start.durationTo(t_end));
        last_result = run_result;

        if (run_result == .err) {
            printRuntimeFailure(init, run_result.err, source);
            vm.runtime.resetDiagArena();
        }
    }

    if (echo_last) |mode| {
        if (last_result) |result| switch (result) {
            .ok => try printResult(vm, mode),
            .err => |failure| {
                printRuntimeFailure(init, failure, source);
                vm.runtime.resetDiagArena();
            },
        };
    }

    revo.vm.debug.printBenchStats(times.items);
}

fn benchSource(init: std.process.Init, gpa: Allocator, path: []const u8, source: []const u8, config: Config) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    vm.setProgramDebugInfo(artifact.spans, source, path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try benchArtifact(init, gpa, &vm, path, artifact, source, config.bench_iters, config.echo_last);
}

fn benchBytecode(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    bytecode_data: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    var deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer deserialized.deinit();

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try benchArtifact(
        init,
        gpa,
        &vm,
        path,
        .{ .instructions = deserialized.instructions, .spans = deserialized.spans },
        "",
        config.bench_iters,
        config.echo_last,
    );
}

fn compileToBytecode(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    path: []const u8,
    source: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    const bytecode = revo.bytecode.serialize(&vm, artifact, gpa) catch |err| {
        printError(init, "serializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer gpa.free(bytecode);

    const output_path: []const u8 = if (config.output_path) |provided|
        provided
    else blk: {
        if (std.mem.endsWith(u8, path, ".rv")) {
            const base = path[0 .. path.len - 3];
            break :blk std.fmt.allocPrint(arena, "{s}.rvo", .{base}) catch {
                printError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        } else {
            break :blk std.fmt.allocPrint(arena, "{s}.rvo", .{path}) catch {
                printError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        }
    };

    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = bytecode,
    }) catch |err| {
        printError(init, "writing bytecode file '{s}' - {}", .{ output_path, err });
        return error.FileError;
    };

    printSuccess(init, "compiled to {s}", .{output_path});
}

pub fn printRuntimeFailure(init: std.process.Init, failure: revo.EvalFailure, source: []const u8) void {
    revo.printEvalError(init.gpa, source, failure);
}

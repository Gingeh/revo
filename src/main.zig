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

const USAGE =
    \\usage: revo [options] [script [args...]]
    \\       revo <command> [options]
    \\
    \\options:
    \\  -e code          run code
    \\  -i               enter repl after executing
    \\  -d,-D,-P         output the the program's result in {display, debug, pretty} mode
    \\  --test           run with test blocks
    \\  -h, --help       show this help message
    \\
    \\commands:
    \\  compile          compile script to bytecode instead of running
    \\                   runs only the comp/proc blocks
    \\  repl             start repl (default with no args)
    \\  version          show version and build info
    \\
++ (if (lsp_enabled)
    \\  lsp              start the lsp
    \\
else
    "") ++
    \\  dis              show bytecode disassembly instead of running
    \\  bench[n]         run with performance counters ([n] iterations, 1 if not specified)
    \\  doc              extract doc comments from a file, dir, or the pwd workspace
    \\                   --html    render as html instead of markdown
    \\                   --splice  splice output into markdown piped on stdin
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
    \\  revo doc script.rv                print extracted docs as markdown
    \\  revo doc --html src/std/iface     render the stdlib reference as html
    \\  revo doc --html src/std/iface < std.md > std.new   splice into a doc page
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
            var stderr = revo.stderr().writer(init.io, &stderr_buf);
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
        const stdin_file = revo.stdin();
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
    // of sources, the pwd workspace, or a piped source; `--html` outputs html,
    // without it outputs markdown; `--html` with piped stdin splices into the page
    if (config.mode == .docs or config.mode == .docs_html) {
        try docs.Cli.run(
            init,
            init.gpa,
            arena,
            config.script_path,
            config.mode == .docs_html,
            config.force_splice,
        );
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
        const stdin_file = revo.stdin();
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

/// revo --options-go-here [subcommand/script name] --rest-goes-to-script
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
        } else if (std.mem.eql(u8, cmd, "doc")) {
            config.mode = .docs;
        } else if (std.mem.eql(u8, cmd, "version")) {
            std.debug.print("revo {s} ({s})\n", .{ build_opts.version, build_opts.git_commit });
            return error.VersionRequested;
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
        } else if (std.mem.eql(u8, arg, "-P")) {
            config.echo_last = .pretty;
        } else if (std.mem.eql(u8, arg, "--test")) {
            config.test_mode = true;
        } else if (std.mem.eql(u8, arg, "--html")) {
            if (config.mode == .docs) config.mode = .docs_html;
        } else if (std.mem.eql(u8, arg, "--splice")) {
            config.force_splice = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{USAGE});
            return error.HelpRequested;
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

const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("src/c/bindings.zig");

const Build = std.Build;
const Module = Build.Module;
const logger = std.log.scoped(.@"build/revo");

const VERSION = "0.1.0a";

const release_targets: []const []const u8 = &.{
    "x86_64-linux-musl",
    // "aarch64-linux-musl",
    // "x86_64-macos",
    "aarch64-macos",
    "x86_64-windows",
    "wasm64-freestanding",
};

const release_target_queries = blk: {
    // zig master's target-query parse path can exceed the default comptime quota???
    @setEvalBranchQuota(200_000);
    // pre-computes queries
    var arr: [release_targets.len]std.Target.Query = undefined;
    var bad_targets: []const u8 = &.{};
    for (release_targets, &arr) |in, *out| {
        out.* = std.Target.Query.parse(.{ .arch_os_abi = in }) catch {
            if (bad_targets.len >= 1) {
                bad_targets = bad_targets ++ ", ";
            }
            bad_targets = bad_targets ++ "\"" ++ in ++ "\"";
        };
    }
    if (bad_targets.len >= 1) {
        @compileError("Invalid target(s): " ++ bad_targets);
    }

    const c_arr = arr;
    break :blk &c_arr;
};

const Features = packed struct {
    isocline: bool = false,
    lsp: bool = false,

    fn isFull(self: Features) bool {
        const info = @typeInfo(Features).@"struct";
        const BackInt = info.backing_integer.?;
        return @popCount(@as(BackInt, @bitCast(self))) == @bitSizeOf(BackInt);
    }
};

const BinaryType = enum { nightly, release };

fn emptyStr(s: []const u8) bool {
    for (s) |c| switch (c) {
        ' ', '\n', '\r', '\t' => continue,
        else => return false,
    } else return true;
}

fn getFeatures(features: []const u8) Features {
    var ret = Features{};
    if (features.len == 0) return ret;

    var it = std.mem.splitScalar(u8, features, ',');
    while (it.next()) |token| {
        if (emptyStr(token)) continue;

        const features_info = comptime @typeInfo(Features).@"struct";
        var matched = false;
        inline for (features_info.field_names) |field_name| {
            if (std.mem.eql(u8, token, field_name)) {
                if (@field(ret, field_name)) {
                    std.log.warn("Duplicate feature: {s}", .{token});
                }
                @field(ret, field_name) = true;
                matched = true;
            }
        }
        if (!matched) std.log.warn("Unknown feature: {s}", .{token});
    }
    return ret;
}

/// for release bin names
fn binName(b: *std.Build, triple: []const u8, btype: BinaryType) []const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{
        .secs = @intCast(std.Io.Clock.real.now(b.graph.io).toSeconds()),
    };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const date_str = b.fmt("{d}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
    return switch (btype) {
        .nightly => b.fmt("revo-nightly-{s}-{s}", .{ triple, date_str }),
        .release => b.fmt("revo-{s}-{s}", .{ VERSION, triple }),
    };
}

pub fn build(b: *Build) !void {
    var target: std.Build.ResolvedTarget = undefined;
    // Defaults to 'musl' toolchain for linux system because otherwise the build fails with default settings,
    // but not when enabled 'llvm' and 'lld'. -hamza (Jun 14 2026)
    var with_glibc: bool = undefined;
    if (builtin.os.tag == .linux) {
        with_glibc = b.option(bool, "glibc", "Build with llvm and link with glibc") orelse false;
        if (with_glibc) {
            target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
        } else {
            target = b.standardTargetOptions(.{ .default_target = .{ .abi = .musl } });
        }
    } else {
        target = b.standardTargetOptions(.{});
    }

    // TODO: nan-boxing stores pointer tags in the high bits of a 64-bit value
    // 32bit builds are unsupported until a good implementation of tagged data is made
    // (wasm32 is fine: 32-bit pointers fit below the tag region)
    const is_freestanding = target.result.os.tag == .freestanding or
        target.result.cpu.arch == .wasm64;

    const optimize = b.standardOptimizeOption(.{});

    // botch: wasm64 has a codegen bug in Debug mode that causes "memory access out of
    // bounds" at runtime for some reason
    // force ReleaseSmall for ALL modules linked into the wasm binary, so the VM code gets the fix too
    const effective_optimize = if (is_freestanding) .small else optimize;
    if (optimize != effective_optimize)
        logger.warn("Debug mode crashes wasm64 builds; forcing ReleaseSmall for all modules", .{});

    const features_str = b.option([]const u8, "features", "available: isocline, lsp") orelse
        // isocline needs libc, lsp is untested on freestanding
        if (is_freestanding) "" else "isocline,lsp";

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "only run tests within the arr",
    ) orelse &.{};

    const lsp_kit_dep = b.dependency("lsp_kit", .{});

    const features = getFeatures(features_str);

    var git_exit_code: u8 = 0; // ignored, but it's a required argument
    const git_output = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &git_exit_code, .ignore) catch VERSION;
    const dev_version = std.mem.trim(u8, git_output, " \n\r");

    // used for dev builds
    const debug_options = b.addOptions();
    debug_options.addOption(bool, "is_freestanding", is_freestanding);
    debug_options.addOption(bool, "isocline", features.isocline);
    debug_options.addOption([]const u8, "version", dev_version);
    debug_options.addOption(bool, "lsp_enabled", features.lsp);
    const debug_options_mod = debug_options.createModule();

    // used for release builds
    // note: is_freestanding captures top-level, not per-release.
    // this doesn't really matter but it might break something
    const release_options = b.addOptions();
    release_options.addOption(bool, "is_freestanding", is_freestanding);
    release_options.addOption(bool, "isocline", features.isocline);
    release_options.addOption([]const u8, "version", VERSION);
    release_options.addOption(bool, "lsp_enabled", features.lsp);
    const release_options_mod = release_options.createModule();

    //
    // modules
    //
    const isocline_mod = blk: {
        if (features.isocline) {
            if (b.lazyDependency("isocline", .{})) |isocline_dep| {
                const ioscline_c = b.addTranslateC(.{
                    .root_source_file = isocline_dep.path("include/isocline.h"),
                    .target = target,
                    .optimize = effective_optimize,
                });
                ioscline_c.addIncludePath(isocline_dep.path("include/"));
                const isocline_mod = ioscline_c.createModule();
                isocline_mod.addCSourceFile(.{
                    .file = isocline_dep.path("src/isocline.c"),
                    .flags = &.{},
                });

                break :blk isocline_mod;
            }
        }

        break :blk b.createModule(.{ .root_source_file = b.addWriteFiles().add("no_isocline.zig", "") });
    };
    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const revo_mod = b.addModule("revo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const c_mod = b.addModule("c", .{
        .root_source_file = b.path("src/c/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const revolt_mod = b.createModule(.{
        .root_source_file = if (features.lsp)
            b.path("src/lsp/server.zig")
        else
            b.path("src/lsp/noop.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
        },
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(if (is_freestanding) "src/main_wasm.zig" else "src/main.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
        .imports = &.{
            .{ .name = "lsp_main", .module = revolt_mod },
        },
    });
    const erevo_mod = if (!is_freestanding)
        b.addModule("erevo", .{
            .root_source_file = b.path("src/c/erevo.zig"),
            .target = target,
            .optimize = effective_optimize,
            .link_libc = !is_freestanding,
        })
    else
        null;

    const all_mods: []const *Module = if (is_freestanding) &.{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod,
    } else &.{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod, erevo_mod.?,
    };
    const imports = [_]Module.Import{
        .{ .name = "revo", .module = revo_mod },
        .{ .name = "vm", .module = vm_mod },
        .{ .name = "c", .module = c_mod },
    };
    const shared_build_options = if (optimize == .debug) debug_options_mod else release_options_mod;
    for (all_mods) |mod| {
        for (imports) |imp| {
            mod.addImport(imp.name, imp.module);
        }
        mod.addImport("build_options", shared_build_options);
    }

    exe_mod.addImport("isocline", isocline_mod);

    const header_wf = b.addWriteFiles();
    const header_data = bindings.data(b.allocator) catch |err| {
        std.debug.print("failed to autogen header\n", .{});
        return err;
    };
    _ = header_wf.add("revo.h", header_data.items);

    const vm_test = b.addTest(.{ .root_module = vm_mod, .filters = test_filters });
    const revo_test = b.addTest(.{ .root_module = revo_mod, .filters = test_filters });
    const exe_test = b.addTest(.{ .root_module = exe_mod, .filters = test_filters });
    const c_test = b.addTest(.{ .root_module = c_mod, .filters = test_filters });
    const revolt_test = b.addTest(.{ .root_module = revolt_mod, .filters = test_filters });

    if (is_freestanding) {
        const wasm_lib = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        wasm_lib.entry = .disabled;
        wasm_lib.rdynamic = true;
        // initial_memory not set, it defaults to 1 wasm page (64kb)
        const wasm_install = b.addInstallArtifact(wasm_lib, .{});
        b.getInstallStep().dependOn(&wasm_install.step);
    } else {
        const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        const lib = b.addLibrary(.{ .name = "erevo", .root_module = erevo_mod.? });

        if (optimize == .debug) exe.lto = .none;
        exe.rdynamic = true;
        if (builtin.os.tag == .linux and with_glibc) {
            exe.use_llvm = true;
            exe.use_lld = true;
        }

        const exe_install = b.addInstallArtifact(exe, .{});
        const lib_install = b.addInstallArtifact(lib, .{});
        const header_install = b.addInstallDirectory(.{
            .source_dir = header_wf.getDirectory(),
            .install_subdir = "revo",
            .install_dir = .header,
        });

        b.getInstallStep().dependOn(&exe_install.step);
        lib_install.step.dependOn(&header_install.step);

        const lib_step = b.step("lib", "build the erevo library");
        lib_step.dependOn(&lib_install.step);

        //
        // run step
        //
        const run_step = b.step("run", "run the cli");
        {
            const run_exe = b.addRunArtifact(exe);
            run_exe.addPassthruArgs();
            run_step.dependOn(&run_exe.step);
        }

        //
        // docs step
        //
        const docs_step = b.step("docs", "generate stdlib reference markdown");
        {
            const docgen_mod = b.createModule(.{
                .root_source_file = b.path("tools/docgen.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = !is_freestanding,
            });
            for (imports) |imp| {
                docgen_mod.addImport(imp.name, imp.module);
            }
            docgen_mod.addImport("build_options", shared_build_options);
            const docgen_exe = b.addExecutable(.{ .name = "docgen", .root_module = docgen_mod });
            const run_docgen = b.addRunArtifact(docgen_exe);
            docs_step.dependOn(&run_docgen.step);
        }

        //
        // check step
        //
        const check_step = b.step("check", "type-check without codegen or linking");
        check_step.dependOn(&vm_test.step);
        check_step.dependOn(&revo_test.step);
        check_step.dependOn(&exe_test.step);
        check_step.dependOn(&c_test.step);
        check_step.dependOn(&revolt_test.step);

        //
        // tests
        //
        const test_step = b.step("test", "run all tests");
        {
            const test_vm_step = b.step("test-vm", "test only the vm module");
            test_vm_step.dependOn(&b.addRunArtifact(vm_test).step);
            test_step.dependOn(test_vm_step);

            const test_revo_step = b.step("test-revo", "test only the revo module");
            test_revo_step.dependOn(&b.addRunArtifact(revo_test).step);
            test_step.dependOn(test_revo_step);

            const test_exe_step = b.step("test-exe", "test only the exe root");
            test_exe_step.dependOn(&b.addRunArtifact(exe_test).step);
            test_step.dependOn(test_exe_step);
        }

        //
        // c test suite
        //
        const test_c_step = b.step("test-c", "run c api tests");
        {
            const c_test_exe = b.addExecutable(.{
                .name = "revo-c-test",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = !is_freestanding,
                }),
            });
            c_test_exe.root_module.addCSourceFile(.{
                .file = b.path("src/c/tests.c"),
                .flags = &.{
                    "-std=c99", "-Wall", "-Wextra",
                },
            });
            c_test_exe.root_module.addIncludePath(header_wf.getDirectory());
            c_test_exe.root_module.linkLibrary(lib);
            c_test_exe.root_module.linkSystemLibrary("m", .{ .needed = true });

            const c_test_run = b.addRunArtifact(c_test_exe);
            test_c_step.dependOn(&c_test_run.step);
        }
    }

    //
    // release step
    //
    const release_step = b.step("release", "build release binaries for all targets");
    {
        const install_options = Build.Step.InstallArtifact.Options{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        };

        for (release_targets, release_target_queries) |target_str, query| {
            const release_target = b.resolveTargetQuery(query);
            const release_is_fs = release_target.result.os.tag == .freestanding or
                release_target.result.cpu.arch == .wasm64;
            const release_optimize: std.builtin.OptimizeMode = if (release_is_fs) .small else .fast;

            const release_lsp_enabled = features.lsp and !release_is_fs;
            const release_isocline_enabled = features.isocline and !release_is_fs;

            const rel_options = b.addOptions();
            rel_options.addOption(bool, "is_freestanding", release_is_fs);
            rel_options.addOption(bool, "isocline", release_isocline_enabled);
            rel_options.addOption([]const u8, "version", VERSION);
            rel_options.addOption(bool, "lsp_enabled", release_lsp_enabled);
            const rel_options_mod = rel_options.createModule();

            const rel_vm_mod = b.createModule(.{
                .root_source_file = b.path("src/vm/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_revo_mod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_c_mod = b.createModule(.{
                .root_source_file = b.path("src/c/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });

            const rel_core_mods: []const *Module = &.{ rel_vm_mod, rel_revo_mod, rel_c_mod };
            for (rel_core_mods) |mod| {
                mod.addImport("revo", rel_revo_mod);
                mod.addImport("vm", rel_vm_mod);
                mod.addImport("c", rel_c_mod);
                mod.addImport("build_options", rel_options_mod);
            }

            const rel_isocline_mod = blk: {
                if (release_isocline_enabled) {
                    if (b.lazyDependency("isocline", .{})) |isocline_dep| {
                        const isocline_c = b.addTranslateC(.{
                            .root_source_file = isocline_dep.path("include/isocline.h"),
                            .target = release_target,
                            .optimize = release_optimize,
                        });
                        isocline_c.addIncludePath(isocline_dep.path("include/"));
                        const mod = isocline_c.createModule();
                        mod.addCSourceFile(.{
                            .file = isocline_dep.path("src/isocline.c"),
                            .flags = &.{},
                        });
                        break :blk mod;
                    }
                }
                break :blk b.createModule(.{
                    .root_source_file = b.addWriteFiles().add(
                        b.fmt("no_isocline_release_{s}.zig", .{target_str}),
                        "",
                    ),
                });
            };

            const rel_revolt_mod = b.createModule(.{
                .root_source_file = if (release_lsp_enabled)
                    b.path("src/lsp/server.zig")
                else
                    b.path("src/lsp/noop.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
                .imports = if (release_lsp_enabled) &[_]Module.Import{
                    .{ .name = "revo", .module = rel_revo_mod },
                    .{ .name = "vm", .module = rel_vm_mod },
                    .{ .name = "c", .module = rel_c_mod },
                    .{ .name = "build_options", .module = rel_options_mod },
                    .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
                } else &.{},
            });

            const release_mod = b.createModule(.{
                .root_source_file = b.path(if (release_is_fs) "src/main_wasm.zig" else "src/main.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
                .imports = &[_]Module.Import{
                    .{ .name = "revo", .module = rel_revo_mod },
                    .{ .name = "vm", .module = rel_vm_mod },
                    .{ .name = "c", .module = rel_c_mod },
                    .{ .name = "build_options", .module = rel_options_mod },
                    .{ .name = "isocline", .module = rel_isocline_mod },
                    .{ .name = "lsp_main", .module = rel_revolt_mod },
                },
            });

            const release_exe = b.addExecutable(.{
                .name = binName(b, target_str, .nightly),
                .root_module = release_mod,
            });
            if (release_is_fs) release_exe.entry = .disabled;
            release_exe.rdynamic = true;

            release_step.dependOn(&b.addInstallArtifact(release_exe, install_options).step);
        }
    }
}

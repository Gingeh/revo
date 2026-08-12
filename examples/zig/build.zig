const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const revo_dep = b.dependency("revo", .{
        .target = target,
        .optimize = optimize,
    });

    const ext = b.addLibrary(.{
        .name = "zrevo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("functions.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "revo", .module = revo_dep.module("revo") },
            },
        }),
        .linkage = .dynamic,
    });

    b.getInstallStep().dependOn(&b.addInstallArtifact(ext, .{}).step);
}

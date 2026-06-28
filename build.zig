const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const quickjs_dep = b.dependency("quickjs", .{});

    // Translate quickjs.h to a Zig module via the build system (replaces @cImport)
    const translate_c = b.addTranslateC(.{
        .root_source_file = quickjs_dep.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(quickjs_dep.path("."));
    const c_module = translate_c.createModule();

    const quickjs = b.addModule("quickjs", .{
        .root_source_file = b.path("src/lib.zig"),
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_module },
        },
    });
    quickjs.addIncludePath(quickjs_dep.path("."));
    quickjs.addCSourceFiles(.{
        .root = quickjs_dep.path("."),
        .files = &.{
            "quickjs.c",
            "libregexp.c",
            "libunicode.c",
            "dtoa.c",
        },
    });

    // Tests

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/test.zig"),
            .link_libc = true,
            .imports = &.{
                .{ .name = "quickjs", .module = quickjs },
            },
        }),
    });

    const test_runner = b.addRunArtifact(tests);

    b.step("test", "Run QuickJS tests").dependOn(&test_runner.step);
}

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("opengl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(b.path("../../vendor/glad/include"));
    translate: {
        const tc = b.lazyImport(@This(), "translate_c") orelse break :translate;
        const dep = b.lazyDependency("translate_c", .{}) orelse break :translate;
        const c: tc.Translator = .init(dep, .{
            .c_source_file = b.path("c.h"),
            .default_init = true,
            .target = target,
            .optimize = optimize,
            .libc_file = if (target.result.os.tag.isDarwin()) blk: {
                switch (try @import("apple_sdk").pathsForTarget(b, target.result)) {
                    inline else => |paths| break :blk paths.libc,
                }
            } else null,
        });
        c.addIncludePath(b.path("../../vendor/glad/include"));
        module.addImport("opengl-c", c.mod);
    }
}

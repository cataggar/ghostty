const std = @import("std");

pub const Targets = packed struct {
    x11: bool = false,
    wayland: bool = false,
};

pub const Versions = struct {
    gtk: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    adwaita: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
};

/// Returns the targets that GTK4 was compiled with.
pub fn targets(b: *std.Build) Targets {
    // Run pkg-config. We allow it to fail so that zig build --help
    // works without all dependencies. The build will fail later when
    // GTK isn't found anyways.
    var code: u8 = undefined;
    const output = b.runAllowFail(
        &.{ pkgConfigExe(b), "--variable=targets", "gtk4" },
        &code,
        .ignore,
    ) catch return .{};

    const x11 = std.mem.find(u8, output, "x11") != null;
    const wayland = std.mem.find(u8, output, "wayland") != null;

    return .{
        .x11 = x11,
        .wayland = wayland,
    };
}

/// Returns the versions of the GTK libraries available to the build.
pub fn versions(b: *std.Build) Versions {
    return .{
        .gtk = packageVersion(b, "gtk4") orelse .{
            .major = 0,
            .minor = 0,
            .patch = 0,
        },
        .adwaita = packageVersion(b, "libadwaita-1") orelse .{
            .major = 0,
            .minor = 0,
            .patch = 0,
        },
    };
}

fn packageVersion(
    b: *std.Build,
    package: []const u8,
) ?std.SemanticVersion {
    var code: u8 = undefined;
    const output = b.runAllowFail(
        &.{ pkgConfigExe(b), "--modversion", package },
        &code,
        .ignore,
    ) catch return null;
    if (code != 0) return null;

    return std.SemanticVersion.parse(
        std.mem.trim(u8, output, &std.ascii.whitespace),
    ) catch null;
}

fn pkgConfigExe(b: *std.Build) []const u8 {
    return b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
}

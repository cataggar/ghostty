//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");

pub const Options = struct {
    /// Subdirectories to join to the base. This avoids extra allocations
    /// when building up the directory. This is commonly the application.
    subdir: ?[]const u8 = null,

    /// The home directory for the user. If this is not set, we will attempt
    /// to look it up which is an expensive process. By setting this, you can
    /// avoid lookups.
    home: ?[]const u8 = null,
};

/// Get the XDG user config directory. The returned value is allocated.
pub fn config(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(alloc, opts, io, env, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(alloc, opts, io, env, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(alloc, opts, io, env, .{
        .env = "XDG_STATE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".local/state",
    });
}

const InternalOptions = struct {
    env: []const u8,
    windows_env: []const u8,
    default_subdir: []const u8,
};

/// Unified helper to get XDG directories that follow a common pattern.
fn dir(
    alloc: Allocator,
    opts: Options,
    io: std.Io,
    env: *const std.process.Environ.Map,
    internal_opts: InternalOptions,
) ![]u8 {
    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.Io.Dir.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    // First check the env var. On Windows we treat `LOCALAPPDATA` as a
    // fallback for `XDG_CONFIG_HOME`.
    const env_var_ = v: {
        if (env.get(internal_opts.env)) |v| {
            if (v.len > 0) break :v v;
        }

        if (comptime builtin.os.tag != .windows) break :v null;

        if (env.get(internal_opts.windows_env)) |v| {
            if (v.len > 0) break :v v;
        }
        break :v null;
    };
    if (env_var_) |env_var| {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.Io.Dir.path.join(alloc, &.{
                env_var,
                subdir,
            });
        }

        return try alloc.dupe(u8, env_var);
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(io, env, &buf)) |home| {
        return try std.Io.Dir.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
}

/// Parses the xdg-terminal-exec specification. This expects argv[0] to
/// be "xdg-terminal-exec".
pub fn parseTerminalExec(args: []const [:0]const u8) ?[]const [:0]const u8 {
    if (!std.mem.eql(
        u8,
        std.Io.Dir.path.basename(args[0]),
        "xdg-terminal-exec",
    )) return null;

    // We expect at least one argument
    if (args.len < 2) return &.{};

    // If the first argument is "-e" we skip it.
    const start: usize = if (std.mem.eql(u8, args[1], "-e")) 2 else 1;
    return args[start..];
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;
    var env = try testing.environ.createMap(alloc);
    defer env.deinit();

    {
        const value = try config(alloc, testing.io, &env, .{});
        defer alloc.free(value);
        try testing.expect(value.len > 0);
    }
}

test "cache directory paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var env = try testing.environ.createMap(alloc);
    defer env.deinit();
    const mock_home = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/Users/test";

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(alloc, testing.io, &env, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.Io.Dir.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(alloc, testing.io, &env, .{
                .home = mock_home,
                .subdir = "ghostty",
            });
            defer alloc.free(cache_path);
            const expected = try std.Io.Dir.path.join(alloc, &.{ mock_home, ".cache", "ghostty" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
    }
}

test "fallback when xdg env empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var test_map = try std.testing.environ.createMap(alloc);
    defer test_map.deinit();

    const temp_home = "/tmp/ghostty-test-home";
    try test_map.put("HOME", temp_home);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, std.Io, *const std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        const expected = try std.Io.Dir.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        try test_map.put(case.name, "");
        const actual = try case.func(alloc, std.testing.io, &test_map, .{});
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env empty and subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var test_map = try std.testing.environ.createMap(alloc);
    defer test_map.deinit();

    const temp_home = "/tmp/ghostty-test-home";
    try test_map.put("HOME", temp_home);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, std.Io, *const std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        const expected = try std.Io.Dir.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        try test_map.put(case.name, "");
        const actual = try case.func(alloc, std.testing.io, &test_map, .{ .subdir = "ghostty" });
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test parseTerminalExec {
    const testing = std.testing;

    {
        const actual = parseTerminalExec(&.{ "a", "b", "c" });
        try testing.expect(actual == null);
    }
    {
        const actual = parseTerminalExec(&.{"xdg-terminal-exec"}).?;
        try testing.expectEqualSlices([:0]const u8, actual, &.{});
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "b", "c" }).?;
        try testing.expectEqualSlices([:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "-e", "a", "b", "c" }).?;
        try testing.expectEqualSlices([:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "-e", "b", "c" }).?;
        try testing.expectEqualSlices([:0]const u8, actual, &.{ "a", "-e", "b", "c" });
    }
}

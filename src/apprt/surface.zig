const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// A fixed-size desktop notification payload sent to the app thread.
    pub const DesktopNotification = struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,

        pub fn init(title: []const u8, body: []const u8) DesktopNotification {
            var result: DesktopNotification = undefined;
            copyUtf8Z(result.title.len, &result.title, title);
            copyUtf8Z(result.body.len, &result.body, body);
            return result;
        }

        /// UTF-8 continuation bytes occupy the range 0x80 through 0xBF.
        fn isUtf8ContinuationByte(byte: u8) bool {
            return switch (byte) {
                0x80...0xBF => true,
                else => false,
            };
        }

        /// Copy as much of `src` as fits, backing up from a UTF-8 continuation
        /// byte so valid input is never truncated in the middle of a codepoint.
        fn copyUtf8Z(
            comptime capacity: usize,
            dst: *[capacity:0]u8,
            src: []const u8,
        ) void {
            var len = @min(src.len, capacity);
            while (len > 0 and
                len < src.len and
                isUtf8ContinuationByte(src[len])) : (len -= 1)
            {}

            @memcpy(dst[0..len], src[0..len]);
            dst[len] = 0;
        }
    };

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Report the window title back to the terminal
    report_title: struct {
        style: ReportTitleStyle,
        input_epoch: u64,
    },

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: struct {
        clipboard: apprt.Clipboard,
        input_epoch: u64,
    },

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: DesktopNotification,

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: terminal.osc.color.ColoredTarget,

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional u8 is the exit code
    /// of the command.
    stop_command: ?u8,

    /// The scrollbar state changed for the surface.
    scrollbar: terminal.Scrollbar,

    /// Search progress update
    search_total: ?usize,

    /// Selected search index change
    search_selected: ?usize,

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "GhosttyApprtChildExited" },
            ),

            .none => void,
        };
    };
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};

pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    if (config.@"command-launch-policy" == .controlled) return false;
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) !Config {
    try config.checkLaunchPreparation(builtin.os.tag);
    // Controlled C overrides must not mutate a map or list shared with the app.
    var copy = if (config.@"command-launch-policy" == .controlled)
        try config.clone(app.alloc)
    else
        config.shallowClone(app.alloc);
    errdefer copy.deinit();
    try copy.prepareLaunch(builtin.os.tag);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Get our previously focused surface for some inherited values.
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = .{ .path = pwd };
            }
        }
    }

    return copy;
}

/// The checker verifies directory accessibility; controlled paths are never
/// expanded, and a failed explicit override cannot retain an older directory.
pub fn applyWorkingDirectory(
    config: *Config,
    path: []const u8,
    context: anytype,
    comptime Checker: type,
) !void {
    const controlled = config.@"command-launch-policy" == .controlled;
    if (controlled) {
        try Config.launch.validateWorkingDirectory(path);
    } else if (path.len == 0) return;

    Checker.check(context, path) catch |err| {
        if (controlled) return err;
        std.log.scoped(.apprt).warn("error checking requested working directory dir={s} err={}", .{ path, err });
        return;
    };
    var value: Config.WorkingDirectory = .{ .path = path };
    if (controlled) {
        value = try value.clone(config.arenaAlloc());
    } else {
        value.finalize(config.arenaAlloc()) catch |err| {
            std.log.scoped(.apprt).warn("error finalizing working directory config dir={s} err={}", .{ path, err });
            return;
        };
    }
    config.@"working-directory" = value;
}

pub fn launchEnvironment(
    policy: Config.launch.Policy,
    context: anytype,
    comptime Provider: type,
) !std.process.Environ.Map {
    return Provider.get(context) catch |err| {
        if (policy == .controlled) return err;
        std.log.scoped(.surface).warn("error getting env map for surface err={}", .{err});
        return Provider.fallback(context);
    };
}

test "launch policy pure working directory override and inheritance" {
    const testing = std.testing;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"window-inherit-working-directory" = true;
    cfg.@"tab-inherit-working-directory" = true;
    cfg.@"split-inherit-working-directory" = true;
    inline for (.{ .window, .tab, .split }) |context|
        try testing.expect(shouldInheritWorkingDirectory(context, &cfg));
    cfg.@"command-launch-policy" = .controlled;
    inline for (.{ .window, .tab, .split }) |context|
        try testing.expect(!shouldInheritWorkingDirectory(context, &cfg));

    const Checker = struct {
        calls: usize = 0,
        fail: bool = true,
        fn check(self: *@This(), _: []const u8) !void {
            self.calls += 1;
            if (self.fail) return error.AccessDenied;
        }
    };
    var checker: Checker = .{};
    cfg.@"working-directory" = .{ .path = "/previous" };
    try testing.expectError(error.AccessDenied, applyWorkingDirectory(&cfg, "/new", &checker, Checker));
    try testing.expectEqual(@as(usize, 1), checker.calls);
    try testing.expectError(error.LaunchWorkingDirectoryMustBeAbsolute, applyWorkingDirectory(&cfg, "", &checker, Checker));
    try testing.expectEqual(@as(usize, 1), checker.calls);
    checker.fail = false;
    try applyWorkingDirectory(&cfg, "/owned space'/child", &checker, Checker);
    try testing.expectEqualStrings("/owned space'/child", cfg.@"working-directory".?.path);
    cfg.@"command-launch-policy" = .normal;
    checker.fail = true;
    try applyWorkingDirectory(&cfg, "/ignored", &checker, Checker);
    try testing.expectEqualStrings("/owned space'/child", cfg.@"working-directory".?.path);
}

test "launch policy pure environment errors never fall back" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const Provider = struct {
        calls: usize = 0,
        fallbacks: usize = 0,
        fail: bool = true,
        fn get(self: *@This()) !std.process.Environ.Map {
            self.calls += 1;
            if (self.fail) return error.EnvironmentUnavailable;
            return .init(std.testing.allocator);
        }
        fn fallback(self: *@This()) std.process.Environ.Map {
            self.fallbacks += 1;
            return .init(std.testing.allocator);
        }
    };
    var provider: Provider = .{};
    try std.testing.expectError(error.EnvironmentUnavailable, launchEnvironment(.controlled, &provider, Provider));
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), provider.fallbacks);
    var normal = try launchEnvironment(.normal, &provider, Provider);
    defer normal.deinit();
    try std.testing.expectEqual(@as(usize, 1), provider.fallbacks);
    provider.fail = false;
    var controlled = try launchEnvironment(.controlled, &provider, Provider);
    defer controlled.deinit();
    try std.testing.expectEqual(@as(usize, 1), provider.fallbacks);
}

test "launch policy pure cwd override allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testWorkingDirectoryAllocation, .{});
}

fn testWorkingDirectoryAllocation(alloc: Allocator) !void {
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"command-launch-policy" = .controlled;
    try applyWorkingDirectory(&cfg, "/owned space'/child", {}, struct {
        fn check(_: void, _: []const u8) !void {}
    });
    try std.testing.expectEqualStrings("/owned space'/child", cfg.@"working-directory".?.path);
}

test "DesktopNotification init" {
    const notification = Message.DesktopNotification.init("Title", "Body");

    try std.testing.expectEqualStrings("Title", std.mem.sliceTo(&notification.title, 0));
    try std.testing.expectEqualStrings("Body", std.mem.sliceTo(&notification.body, 0));
}

test "copyUtf8Z handles len at the final byte of every UTF-8 sequence length" {
    const DesktopNotification = Message.DesktopNotification;

    var dst_1_byte: [1:0]u8 = undefined;
    const src_ending_in_1_byte_codepoint = "ab";
    try std.testing.expect(!DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_1_byte_codepoint[dst_1_byte.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_1_byte.len,
        &dst_1_byte,
        src_ending_in_1_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_1_byte, 0));

    var dst_2_bytes: [2:0]u8 = undefined;
    const src_ending_in_2_byte_codepoint = "aЯ";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_2_byte_codepoint[dst_2_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_2_bytes.len,
        &dst_2_bytes,
        src_ending_in_2_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_2_bytes, 0));

    var dst_3_bytes: [3:0]u8 = undefined;
    const src_ending_in_3_byte_codepoint = "a€";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_3_byte_codepoint[dst_3_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_3_bytes.len,
        &dst_3_bytes,
        src_ending_in_3_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_3_bytes, 0));

    var dst_4_bytes: [4:0]u8 = undefined;
    const src_ending_in_4_byte_codepoint = "a😀";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_4_byte_codepoint[dst_4_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_4_bytes.len,
        &dst_4_bytes,
        src_ending_in_4_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_4_bytes, 0));
}

test "copyUtf8Z keeps a complete codepoint at the truncation boundary" {
    var dst: [5:0]u8 = undefined;

    Message.DesktopNotification.copyUtf8Z(dst.len, &dst, "abcЯz");

    try std.testing.expectEqualStrings("abcЯ", std.mem.sliceTo(&dst, 0));
}

test "copyUtf8Z preserves UTF-8 that fits" {
    var dst: [5:0]u8 = undefined;

    Message.DesktopNotification.copyUtf8Z(dst.len, &dst, "abcЯ");

    try std.testing.expectEqualStrings("abcЯ", std.mem.sliceTo(&dst, 0));
}

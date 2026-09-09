//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
pub const Thread = @This();

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// The number of milliseconds to coalesce certain messages like resize for.
    /// Not all message types are coalesced.
    const min_ms = 25;

    resize: ?renderer.Size = null,
    input_epoch: u64 = 0,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,
loop_deinitialized: bool = false,

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    self.stop.deinit();
    if (!self.loop_deinitialized) self.loop.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    // Callback storage must survive startup failure and the drain loop too.
    var cb: CallbackData = .{
        .self = self,
        .io = io,
        .data = .{
            .alloc = self.alloc,
            .loop = &self.loop,
            .renderer_state = io.renderer_state,
            .surface_mailbox = io.surface_mailbox,
            .mailbox = &io.mailbox,
            .backend = undefined,
        },
    };
    defer {
        self.finishLoop(io, &cb.data);
        if (cb.data.backend_initialized) cb.data.deinit();
    }
    io.mailbox.spsc.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);

    // Call child function so we can use errors...
    self.threadMain_(&cb) catch |err| {
        io.mailbox.spsc.input.fail();
        log.warn("error in io thread err={}", .{err});

        // Use an arena to simplify memory management below
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // If there is an error, we replace our terminal screen with
        // the error message. It might be better in the future to send
        // the error to the surface thread and let the apprt deal with it
        // in some way but this works for now. Without this, the user would
        // just see a blank terminal window.
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const t = io.renderer_state.terminal;

        // Hide the cursor
        t.modes.set(.cursor_visible, false);

        // This is weird but just ensures that no matter what our underlying
        // implementation we have the errors below. For example, Windows doesn't
        // have "OpenptyFailed".
        const Err = @TypeOf(err) || error{
            OpenptyFailed,
            InputNotFound,
            InputFailed,
        };

        switch (@as(Err, @errorCast(err))) {
            error.OpenptyFailed => {
                const str =
                    \\Your system cannot allocate any more pty devices.
                    \\
                    \\Ghostty requires a pty device to launch a new terminal.
                    \\This error is usually due to having too many terminal
                    \\windows open or having another program that is using too
                    \\many pty devices.
                    \\
                    \\Please free up some pty devices and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            error.InputNotFound,
            error.InputFailed,
            => {
                const str =
                    \\A configured `input` path was not found, was not readable,
                    \\was too large, or the underlying pty failed to accept
                    \\the write.
                    \\
                    \\Ghostty can't continue since it can't guarantee that
                    \\initial terminal state will be as desired. Please review
                    \\the value of `input` in your configuration file and
                    \\ensure that all the path values exist and are readable.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            else => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\error starting IO thread: {}
                    \\
                    \\The underlying shell or command was unable to be started.
                    \\This error is usually due to exhausting a system resource.
                    \\If this looks like a bug, please report it.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{err},
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
        }
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

/// Called only after run has returned and no more callbacks will dispatch.
fn finishLoop(self: *Thread, io: *termio.Termio, data: *termio.Termio.ThreadData) void {
    io.mailbox.close();
    // There is now exactly one reaper: either the process watcher already
    // reported exit, or threadExit stops and reaps the remaining child.
    if (data.backend_initialized) io.threadExit(data);
    self.loop.deinit();
    self.loop_deinitialized = true;
    if (data.backend_initialized) data.backend.exec.writerLoopDeinitialized();
}

fn threadMain_(self: *Thread, cb: *CallbackData) !void {
    const io = cb.io;
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Cleanup is owned by threadMain, including partially completed startup.
    try io.threadEnter(self, &cb.data);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;
    const data = &cb.data;

    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }

    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var redraw: bool = false;
    while (mailbox.pop(global.io())) |envelope| {
        const message = envelope.message;
        data.input_epoch = envelope.input_epoch;
        // If we have a message we always redraw
        redraw = true;

        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .input_barrier => |token| data.backend.exec.inputBarrier(token),
            .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
            .visibility_report => |v| try io.visibilityReport(
                data,
                v.visible,
                v.force,
            ),
            .crash => @panic("crash request, crashing intentionally"),
            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try io.changeConfig(data, config.ptr);
            },
            .inspector => |v| self.flags.has_inspector = v,
            .resize => |v| self.handleResize(cb, v),
            .size_report => |v| try io.sizeReport(data, v),
            .clear_screen => |v| try io.clearScreen(data, v.history),
            .scroll_viewport => |v| io.scrollViewport(v),
            .selection_scroll => |v| {
                if (v) {
                    self.startScrollTimer(cb);
                } else {
                    self.stopScrollTimer();
                }
            },
            .jump_to_prompt => |v| try io.jumpToPrompt(v),
            .start_synchronized_output => self.startSynchronizedOutput(cb),
            .linefeed_mode => |v| self.flags.linefeed_mode = v,
            .focused => |v| try io.focusGained(data, v),
            .write_small => |v| try io.queueWrite(
                data,
                v.data[0..v.len],
                self.flags.linefeed_mode,
            ),
            .write_stable => |v| try io.queueWrite(
                data,
                v,
                self.flags.linefeed_mode,
            ),
            .write_alloc => |v| {
                defer v.alloc.free(v.data);
                try io.queueWrite(
                    data,
                    v.data,
                    self.flags.linefeed_mode,
                );
            },
        }
    }

    // Trigger a redraw after we've drained so we don't waste cyces
    // messaging a redraw.
    if (redraw) {
        try io.renderer_wakeup.notify();
    }
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;
    self.coalesce_data.input_epoch = cb.data.input_epoch;

    // If the timer is already active we just return. In the future we want
    // to reset the timer up to a maximum wait time but for now this ensures
    // relatively smooth resizing.
    if (self.coalesce_c.state() == .active) return;

    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        cb.data.input_epoch = cb.self.coalesce_data.input_epoch;
        cb.io.resize(&cb.data, v) catch |err| {
            cb.io.mailbox.spsc.input.fail();
            log.warn("error during resize err={}", .{err});
        };
    }

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        if (cb_) |cb| cb.io.mailbox.spsc.input.fail();
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err| {
        cb.io.mailbox.spsc.input.fail();
        log.err("error draining mailbox err={}", .{err});
    };

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const cb = cb_.?;
    cb.self.flags.drain = true;
    if (cb.data.backend_initialized) {
        cb.io.backend.exec.stopWriter(&cb.data);
    } else cb.self.loop.stop();
    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}

/// No GUI, child process, or timing-based readiness: the real PTY slave is
/// deliberately unread until the test elects to relieve backpressure.
const TestPty = struct {
    const terminal = @import("../terminal/main.zig");
    const Pty = @import("../pty.zig").Pty;
    const c = @cImport({
        @cInclude("termios.h");
        @cInclude("fcntl.h");
        @cInclude("sys/ioctl.h");
        @cInclude("sys/stat.h");
    });

    pty: Pty,
    thread: Thread,
    io: termio.Termio,
    cb: CallbackData,
    mutex: std.Io.Mutex = .init,
    render_state: renderer.State,
    child_subprocess: bool = false,

    fn create() !*TestPty {
        const alloc = std.testing.allocator;
        const self = try alloc.create(TestPty);
        errdefer alloc.destroy(self);
        self.* = undefined;
        self.mutex = .init;
        self.child_subprocess = false;
        self.pty = try Pty.open(.{});
        errdefer self.pty.deinit();
        errdefer _ = std.posix.system.close(self.pty.slave);
        var attrs: c.termios = undefined;
        try std.testing.expectEqual(0, c.tcgetattr(self.pty.slave, &attrs));
        c.cfmakeraw(&attrs);
        try std.testing.expectEqual(0, c.tcsetattr(self.pty.slave, c.TCSANOW, &attrs));
        for ([_]std.posix.fd_t{ self.pty.master, self.pty.slave }) |fd| {
            const flags = c.fcntl(fd, c.F_GETFL);
            try std.testing.expect(flags >= 0);
            try std.testing.expectEqual(0, c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK));
        }
        self.thread = try .init(alloc);
        errdefer self.thread.deinit();
        self.io.alloc = alloc;
        self.io.mailbox = try .initSPSC(alloc);
        errdefer self.io.mailbox.deinit(alloc);
        self.io.backend = .{ .exec = .{ .subprocess = undefined } };
        self.io.renderer_wakeup = try xev.Async.init();
        errdefer self.io.renderer_wakeup.deinit();
        self.io.renderer_mailbox = try renderer.Thread.Mailbox.create(alloc);
        errdefer self.io.renderer_mailbox.destroy(alloc);
        self.io.terminal = try terminal.Terminal.init(global.io(), alloc, .{
            .cols = 80,
            .rows = 24,
        });
        errdefer self.io.terminal.deinit(alloc);
        self.render_state = .{
            .mutex = &self.mutex,
            .terminal = &self.io.terminal,
        };
        self.io.renderer_state = &self.render_state;
        self.io.last_cursor_reset = null;
        self.io.size = .{
            .screen = .{ .width = 640, .height = 384 },
            .cell = .{ .width = 8, .height = 16 },
            .padding = .{},
        };
        self.io.config.conditional_state = .{};
        self.io.terminal_stream = .init(.{
            .allocator = alloc,
            .handler = .{
                .alloc = alloc,
                .size = &self.io.size,
                .terminal = &self.io.terminal,
                .termio_mailbox = &self.io.mailbox,
                .surface_mailbox = undefined,
                .renderer_state = &self.render_state,
                .renderer_mailbox = self.io.renderer_mailbox,
                .renderer_wakeup = self.io.renderer_wakeup,
                .enquiry_response = "",
                .osc_color_report_format = .@"16-bit",
                .clipboard_write = .deny,
                .seen_title = true,
            },
        });
        errdefer self.io.terminal_stream.deinit();
        self.cb = .{
            .self = &self.thread,
            .io = &self.io,
            .data = .{
                .alloc = alloc,
                .loop = &self.thread.loop,
                .renderer_state = &self.render_state,
                .surface_mailbox = undefined,
                .mailbox = &self.io.mailbox,
                .backend = .{ .exec = .{
                    .start = .now(global.io(), .awake),
                    .write_stream = xev.Stream.initFd(self.pty.master),
                    .input = &self.io.mailbox.spsc.input,
                    .process = null,
                    .read_thread = undefined,
                    .read_thread_pipe = undefined,
                    .read_thread_fd = self.pty.master,
                    .termios_timer = try xev.Timer.init(),
                } },
            },
        };
        return self;
    }

    fn destroy(self: *TestPty) void {
        // Deinitialize the loop before freeing any callback storage even on
        // assertion failure. No callback may run after this point.
        if (!self.thread.loop_deinitialized) {
            self.cb.data.backend.exec.stopWrites(&self.thread.loop);
            const start = std.Io.Timestamp.now(global.io(), .awake);
            while (!self.thread.loop.stopped()) {
                self.thread.loop.run(.no_wait) catch @panic("PTY fixture shutdown failed");
                if (start.untilNow(global.io(), .awake).toMilliseconds() > 5000)
                    @panic("PTY fixture shutdown timed out");
            }
        }
        if (self.cb.data.backend_initialized) {
            if (!self.thread.loop_deinitialized)
                self.thread.finishLoop(&self.io, &self.cb.data);
            self.cb.data.deinit();
        } else {
            if (!self.thread.loop_deinitialized) {
                self.thread.loop.deinit();
                self.thread.loop_deinitialized = true;
            }
            self.cb.data.backend.exec.writerLoopDeinitialized();
            self.cb.data.backend.exec.write_pool.deinit(std.testing.allocator);
            self.cb.data.backend.exec.termios_timer.deinit();
        }
        self.thread.deinit();
        if (self.child_subprocess) self.io.backend.exec.deinit();
        self.io.terminal_stream.deinit();
        self.io.terminal.deinit(std.testing.allocator);
        self.io.renderer_mailbox.destroy(std.testing.allocator);
        self.io.renderer_wakeup.deinit();
        self.io.mailbox.deinit(std.testing.allocator);
        _ = std.posix.system.close(self.pty.slave);
        self.pty.deinit();
        std.testing.allocator.destroy(self);
    }

    fn drainMailbox(self: *TestPty) !void {
        try self.thread.drainMailbox(&self.cb);
    }

    fn read(self: *TestPty, expected: u8) !usize {
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = std.posix.read(self.pty.slave, &buf) catch |err| switch (err) {
                error.WouldBlock => return total,
                else => return err,
            };
            if (n == 0) return total;
            for (buf[0..n]) |byte| try std.testing.expectEqual(expected, byte);
            total += n;
        }
    }

    fn finish(self: *TestPty, expected: u8) !usize {
        const start = std.Io.Timestamp.now(global.io(), .awake);
        var total: usize = 0;
        while (self.cb.data.backend.exec.write_pending != 0) {
            try self.thread.loop.run(.no_wait);
            total += try self.read(expected);
            if (start.untilNow(global.io(), .awake).toMilliseconds() > 5000)
                return error.WriterTimeout;
        }
        return total + try self.read(expected);
    }
};

const TestEpollPtyWrite = struct {
    const c = TestPty.c;
    const Identity = struct {
        device: c.dev_t,
        number: c_uint,
    };

    fd: std.posix.fd_t,
    identity: Identity,

    fn diagnose(exec: *termio.Exec.ThreadData, master: std.posix.fd_t, reason: []const u8) void {
        if (exec.write_queue.value.epoll.head) |head| {
            const flags = head.completion.flags;
            std.debug.print(
                "epoll writer {s}: pending={d} sampled_fd={d} sampled_state={s} dup={} master_fd={d}\n",
                .{ reason, exec.write_pending, flags.dup_fd, @tagName(flags.state), flags.dup, master },
            );
        } else {
            std.debug.print("epoll writer {s}: pending={d} queue=empty master_fd={d}\n", .{
                reason, exec.write_pending, master,
            });
        }
    }

    fn identityOf(fd: std.posix.fd_t) !?Identity {
        var stat: c.struct_stat = undefined;
        switch (std.posix.errno(c.fstat(fd, &stat))) {
            .SUCCESS => {},
            .BADF => return null,
            else => return error.PtyDescriptorIdentityFailed,
        }
        if (stat.st_mode & c.S_IFMT != c.S_IFCHR) return null;
        var number: c_uint = undefined;
        switch (std.posix.errno(c.ioctl(fd, c.TIOCGPTN, &number))) {
            .SUCCESS => {},
            .BADF, .NOTTY, .INVAL => return null,
            else => return error.PtyDescriptorIdentityFailed,
        }
        return .{ .device = stat.st_dev, .number = number };
    }

    fn count(identity: Identity) !usize {
        const io = global.io();
        var dir = try std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true });
        defer dir.close(io);
        var iter = dir.iterate();
        var result: usize = 0;
        while (try iter.next(io)) |entry| {
            const fd = try std.fmt.parseInt(std.posix.fd_t, entry.name, 10);
            const actual = try identityOf(fd) orelse continue;
            if (std.meta.eql(identity, actual)) result += 1;
        }
        return result;
    }

    fn capture(exec: *termio.Exec.ThreadData, master: std.posix.fd_t) !TestEpollPtyWrite {
        errdefer |err| if (err != error.WriterNotRegistered)
            diagnose(exec, master, @errorName(err));
        const head = exec.write_queue.value.epoll.head orelse return error.WriterQueueEmpty;
        // queueWrite can complete the head and enqueue another during one
        // tick. The new head is .adding with dup_fd=0, not an owned descriptor.
        if (head.completion.flags.state != .active) return error.WriterNotRegistered;
        try std.testing.expect(head.completion.flags.dup);
        const fd = head.completion.flags.dup_fd;
        try std.testing.expect(fd != master);
        const identity = try identityOf(master) orelse return error.MasterPtyMissing;
        try std.testing.expectEqual(identity, try identityOf(fd) orelse
            return error.WriterPtyMissing);
        // Exactly the original master and this registered write duplicate.
        try std.testing.expectEqual(2, try count(identity));
        return .{ .fd = fd, .identity = identity };
    }

    fn expectRetired(self: TestEpollPtyWrite, master: std.posix.fd_t) !void {
        errdefer |err| std.debug.print(
            "epoll writer cleanup {s}: sampled_fd={d} sampled_state=active current_fd_flags={d} master_fd={d} pty_device={d} pty_number={d}\n",
            .{ @errorName(err), self.fd, c.fcntl(self.fd, c.F_GETFD), master, self.identity.device, self.identity.number },
        );
        // The original master remains open, so its devpts index cannot be
        // recycled. An old fd number may, however, now name an unrelated file.
        try std.testing.expectEqual(self.identity, try identityOf(master) orelse
            return error.MasterPtyMissing);
        if (try identityOf(self.fd)) |actual|
            try std.testing.expect(!std.meta.eql(self.identity, actual));
        // Check every descriptor, not just the sampled numeric slot: any
        // later head's leaked duplicate must fail this assertion as well.
        try std.testing.expectEqual(1, try count(self.identity));
    }
};

fn testEpollFirstTickHeadAdvance() !void {
    const testing = std.testing;
    const f = try TestPty.create();
    defer f.destroy();
    const exec = &f.cb.data.backend.exec;
    errdefer TestEpollPtyWrite.diagnose(exec, f.pty.master, "first-tick head advance");
    f.io.queueMessage(.{ .write_stable = "first" }, .unlocked);
    f.io.queueMessage(.{ .write_stable = "second" }, .unlocked);
    try f.drainMailbox();
    try testing.expectEqual(2, exec.write_pending);
    const first = exec.write_queue.value.epoll.head.?;

    // The empty raw PTY is writable. One tick finishes the first request,
    // but its callback only queues the second for the NEXT submission pass.
    try f.thread.loop.run(.no_wait);
    try testing.expectEqual(1, exec.write_pending);
    const second = exec.write_queue.value.epoll.head.?;
    try testing.expect(first != second);
    try testing.expectEqual(.adding, second.completion.flags.state);
    try testing.expectEqual(0, second.completion.flags.dup_fd);
    try testing.expectError(error.WriterNotRegistered, TestEpollPtyWrite.capture(exec, f.pty.master));
}

test "input quiescence real PTY backpressure, mailbox generations, and output" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios)
        return error.SkipZigTest;
    try testPtyInputBarrier();
}

test "input quiescence real PTY barrier Linux epoll" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const old = xev.backend;
    defer xev.backend = old;
    if (!xev.prefer(.epoll)) return error.EpollBackendUnavailable;
    try testPtyInputBarrier();
}

test "input quiescence real PTY barrier Linux io_uring" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const old = xev.backend;
    defer xev.backend = old;
    if (!xev.prefer(.io_uring)) return error.IoUringBackendUnavailable;
    try testPtyInputBarrier();
}

fn testPtyInputBarrier() !void {
    const testing = std.testing;
    const f = try TestPty.create();
    defer f.destroy();
    const input = &f.io.mailbox.spsc.input;

    const paste = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(paste);
    @memset(paste, 'P');
    f.io.queueMessage(try termio.Message.writeReq(testing.allocator, paste), .unlocked);
    try f.drainMailbox();
    try testing.expectEqual(4096, f.cb.data.backend.exec.write_pending);

    // Fill the OS queue without reading the slave. The writer must remain
    // pending even after the IO mailbox and barrier have been processed.
    for (0..256) |_| try f.thread.loop.run(.no_wait);
    try testing.expect(f.cb.data.backend.exec.write_pending > 0);
    const old_epoch = input.snapshot();
    f.io.queueMessage(.{ .write_stable = "mailbox-old" }, .unlocked);
    const token = f.io.mailbox.quiesce();
    const closed_epoch = input.snapshot();
    f.io.queueMessage(.{ .write_stable = "gated" }, .unlocked);
    try f.drainMailbox();
    try testing.expectEqual(.pending, input.status(token));
    try testing.expect(!input.resumeInput(token));

    // Output parsing and local scroll still work. Its DSR response is gated.
    f.io.processOutput("visible output\r\n\x1b[6n");
    try testing.expectEqual(1, f.io.terminal.screens.active.cursor.y);
    const screen = f.io.terminal.screens.active;
    const selected = try screen.selectionString(testing.allocator, .{
        .sel = .init(
            screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
            screen.pages.pin(.{ .active = .{ .x = 13, .y = 0 } }).?,
            false,
        ),
        .trim = false,
    });
    defer testing.allocator.free(selected);
    try testing.expectEqualStrings("visible output", selected);
    f.io.queueMessage(.{ .scroll_viewport = .top }, .unlocked);
    try f.drainMailbox();
    try testing.expectEqual(paste.len, try f.finish('P'));
    try testing.expectEqual(.ready, input.status(token));

    // Delayed producers can publish after READY, including after resume.
    // Captured old/closed epochs must not acquire the new admission epoch.
    f.io.mailbox.sendWithEpoch(.{ .write_stable = "late-old" }, null, old_epoch);
    f.io.mailbox.sendWithEpoch(.{ .write_stable = "late-gated" }, null, closed_epoch);
    f.io.queueMessage(.{ .size_report = .mode_2048 }, .unlocked);
    try testing.expect(input.resumeInput(token));
    try f.drainMailbox();
    try testing.expectEqual(0, f.cb.data.backend.exec.write_pending);
    try testing.expectEqual(0, try f.read('N'));
    f.io.queueMessage(.{ .write_stable = "NNN" }, .unlocked);
    try f.drainMailbox();
    try testing.expectEqual(3, try f.finish('N'));
}

test "input quiescence backend allocation failure and mailbox shutdown" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios)
        return error.SkipZigTest;
    const testing = std.testing;
    const f = try TestPty.create();
    defer f.destroy();
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    f.io.alloc = failing.allocator();
    f.io.queueMessage(.{ .write_stable = "cannot allocate write request" }, .unlocked);
    try testing.expectError(error.OutOfMemory, f.drainMailbox());
    const token = f.io.mailbox.quiesce();
    try f.drainMailbox();
    try testing.expectEqual(.failed, f.io.mailbox.spsc.input.status(token));
    try testing.expectEqual(0, f.cb.data.backend.exec.write_pending);
    f.io.mailbox.close();
    f.io.mailbox.send(try termio.Message.writeReq(
        testing.allocator,
        @as([]const u8, "a message large enough to require an allocation after shutdown"),
    ), null);
    try testing.expect(f.io.mailbox.spsc.queue.pop(global.io()) == null);
}

test "input quiescence child exit cannot report ready" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios)
        return error.SkipZigTest;
    const f = try TestPty.create();
    defer f.destroy();
    f.cb.data.backend.exec.exited = true;
    const token = f.io.mailbox.quiesce();
    try f.drainMailbox();
    try std.testing.expectEqual(.failed, f.io.mailbox.spsc.input.status(token));
    try std.testing.expect(!f.io.mailbox.spsc.input.resumeInput(token));
}

test "input quiescence full mailbox and teardown while writer pending" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .ios)
        return error.SkipZigTest;
    const testing = std.testing;
    const f = try TestPty.create();
    defer f.destroy();
    const input = &f.io.mailbox.spsc.input;
    for (0..64) |_| f.io.mailbox.send(.{ .write_stable = "x" }, null);
    const rejected = f.io.mailbox.quiesce();
    try testing.expectEqual(.failed, input.status(rejected));
    try f.drainMailbox();
    const retry = f.io.mailbox.quiesce();
    try f.drainMailbox();
    try testing.expect(input.resumeInput(retry));

    const paste = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(paste);
    @memset(paste, 'P');
    f.io.queueMessage(try termio.Message.writeReq(testing.allocator, paste), .unlocked);
    try f.drainMailbox();
    for (0..128) |_| try f.thread.loop.run(.no_wait);
    const token = f.io.mailbox.quiesce();
    try f.drainMailbox();
    try testing.expectEqual(.pending, input.status(token));
    f.cb.data.backend.exec.stopWrites(&f.thread.loop);
    const start = std.Io.Timestamp.now(global.io(), .awake);
    while (!f.thread.loop.stopped()) {
        try f.thread.loop.run(.no_wait);
        if (start.untilNow(global.io(), .awake).toMilliseconds() > 5000)
            return error.CancellationTimeout;
    }
    f.thread.loop.deinit();
    f.thread.loop_deinitialized = true;
    f.cb.data.backend.exec.writerLoopDeinitialized();
    try testing.expectEqual(0, f.cb.data.backend.exec.write_pending);
    try testing.expect(!f.cb.data.backend.exec.write_cancel_pending);
    try testing.expectEqual(.failed, input.status(token));
    try testing.expect(!input.resumeInput(token));
}

test "input quiescence real child writer teardown" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    try testChildWriterTeardown();
}

test "input quiescence real child writer teardown Linux epoll" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const old = xev.backend;
    defer xev.backend = old;
    if (!xev.prefer(.epoll)) return error.EpollBackendUnavailable;
    try testChildWriterTeardown();
}

test "input quiescence real child writer teardown Linux io_uring" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const old = xev.backend;
    defer xev.backend = old;
    if (!xev.prefer(.io_uring)) return error.IoUringBackendUnavailable;
    try testChildWriterTeardown();
}

fn testChildWriterTeardown() !void {
    const testing = std.testing;
    const apprt = @import("../apprt.zig");
    const App = @import("../App.zig");
    const c = TestPty.c;
    if (comptime @import("../build_config.zig").app_runtime != .none)
        return error.HeadlessRuntimeRequired;
    if (comptime builtin.os.tag == .linux)
        if (xev.backend == .epoll) try testEpollFirstTickHeadAdvance();

    // Exercise ordinary, unopted shutdown too. Starting the production
    // backend before its loop lets the fixture establish backpressure without
    // reading mutable writer state concurrently or using a readiness timer.
    for ([_]bool{ false, true }) |quiesce| {
        var rt_app: apprt.App = .{};
        var surface: @import("../Surface.zig") = undefined;
        const app_queue = try App.Mailbox.Queue.create(testing.allocator);
        defer app_queue.destroy(testing.allocator);
        const f = try TestPty.create();
        defer f.destroy();
        f.io.surface_mailbox = .{
            .surface = &surface,
            .app = .{ .rt_app = &rt_app, .mailbox = app_queue },
        };
        f.io.terminal_stream.handler.surface_mailbox = f.io.surface_mailbox;
        f.io.thread_enter_state = null;
        f.io.backend.exec.subprocess = .{
            .arena = .init(testing.allocator),
            .cwd = null,
            .env = null,
            .args = &.{ "/bin/sleep", "30" },
            .grid_size = .{ .columns = 80, .rows = 24 },
            .screen_size = .{ .width = 640, .height = 384 },
            .rt_pre_exec_info = .{},
            .rt_post_fork_info = .{},
        };
        f.child_subprocess = true;
        const placeholder = f.cb.data.backend;
        f.io.threadEnter(&f.thread, &f.cb.data) catch |err| {
            f.cb.data.backend = placeholder;
            return err;
        };
        var placeholder_timer = placeholder.exec.termios_timer;
        placeholder_timer.deinit();
        const exec = &f.cb.data.backend.exec;
        try testing.expect(exec.process != null);
        try testing.expectEqual(.active, exec.process_wait_c.state());
        const pid = f.io.backend.exec.subprocess.process.?.fork_exec.pid.?;
        const fd = f.io.backend.exec.subprocess.pty.?.master;
        var attrs: c.termios = undefined;
        try testing.expectEqual(0, c.tcgetattr(fd, &attrs));
        c.cfmakeraw(&attrs);
        try testing.expectEqual(0, c.tcsetattr(fd, c.TCSANOW, &attrs));
        const flags = c.fcntl(fd, c.F_GETFL);
        try testing.expect(flags >= 0);
        try testing.expectEqual(0, c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK));

        const bytes = try testing.allocator.alloc(u8, 256 * 1024);
        defer testing.allocator.free(bytes);
        @memset(bytes, 'P');
        const fill_start = std.Io.Timestamp.now(global.io(), .awake);
        while (true) {
            switch (std.posix.errno(std.posix.system.write(fd, bytes.ptr, bytes.len))) {
                .SUCCESS => {},
                .AGAIN => break,
                .INTR => continue,
                else => return error.PtyFillFailed,
            }
            if (fill_start.untilNow(global.io(), .awake).toMilliseconds() > 5000)
                return error.PtyBackpressureTimeout;
        }
        f.io.queueMessage(try termio.Message.writeReq(testing.allocator, bytes), .unlocked);
        try f.drainMailbox();
        try testing.expectEqual(4096, exec.write_pending);
        const token = if (quiesce) f.io.mailbox.quiesce() else 0;
        try f.drainMailbox();
        if (quiesce) try testing.expectEqual(.pending, exec.input.status(token));

        f.io.mailbox.spsc.wakeup.wait(&f.thread.loop, &f.thread.wakeup_c, CallbackData, &f.cb, wakeupCallback);
        f.thread.stop.wait(&f.thread.loop, &f.thread.stop_c, CallbackData, &f.cb, stopCallback);
        if (comptime builtin.os.tag == .linux) {
            if (xev.backend == .epoll) {
                // Reproduce the formerly accepted default descriptor value
                // deterministically, without depending on write timing.
                try testing.expectEqual(0, exec.write_queue.value.epoll.head.?.completion.flags.dup_fd);
                try testing.expectError(error.WriterNotRegistered, TestEpollPtyWrite.capture(exec, fd));
            }
        }
        // Submit the real process watch and write before requesting stop.
        try f.thread.loop.run(.no_wait);
        try testing.expect(exec.write_pending > 0);
        const epoll_write: ?TestEpollPtyWrite = watch: {
            if (comptime builtin.os.tag == .linux) {
                if (xev.backend == .epoll) {
                    const watch_start = std.Io.Timestamp.now(global.io(), .awake);
                    while (true) {
                        break :watch TestEpollPtyWrite.capture(exec, fd) catch |err| switch (err) {
                            error.WriterNotRegistered => {
                                if (watch_start.untilNow(global.io(), .awake).toMilliseconds() > 5000) {
                                    TestEpollPtyWrite.diagnose(exec, fd, "registration timeout");
                                    return error.WriterRegistrationTimeout;
                                }
                                try f.thread.loop.run(.no_wait);
                                continue;
                            },
                            else => return err,
                        };
                    }
                }
            }
            break :watch null;
        };
        const Worker = struct {
            fixture: *TestPty,
            done: std.atomic.Value(bool) = .init(false),

            fn run(self: *@This()) void {
                defer self.done.store(true, .release);
                defer self.fixture.thread.finishLoop(&self.fixture.io, &self.fixture.cb.data);
                self.fixture.thread.loop.run(.until_done) catch
                    @panic("real-child writer event loop failed");
            }
        };
        var worker: Worker = .{ .fixture = f };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        defer thread.join();
        f.thread.stop.notify() catch @panic("writer stop notification failed");
        const start = std.Io.Timestamp.now(global.io(), .awake);
        while (!worker.done.load(.acquire)) {
            if (start.untilNow(global.io(), .awake).toMilliseconds() > 5000) {
                // Abort rather than hanging the runner in join. The child is
                // fixture-owned, and also has a finite lifetime as a fallback.
                std.posix.kill(pid, .KILL) catch {};
                @panic("real-child writer shutdown exceeded five seconds");
            }
            try std.Io.sleep(global.io(), .fromMilliseconds(1), .awake);
        }
        try testing.expect(f.thread.loop_deinitialized);
        try testing.expectEqual(0, exec.write_pending);
        try testing.expect(!exec.write_cancel_pending);
        try testing.expect(f.io.backend.exec.subprocess.process == null);
        try testing.expectEqual(.CHILD, std.posix.errno(
            std.posix.system.waitpid(pid, null, std.c.W.NOHANG),
        ));
        if (comptime builtin.os.tag == .linux)
            if (epoll_write) |watch| try watch.expectRetired(fd);
        if (quiesce) {
            try testing.expectEqual(.failed, exec.input.status(token));
            try testing.expect(!exec.input.resumeInput(token));
        }
    }
}

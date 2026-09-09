const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(Envelope, 64);

pub const Envelope = struct {
    message: termio.Message,
    input_epoch: u64,

    pub fn deinit(self: Envelope) void {
        self.message.deinit();
    }
};

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
        input: termio.InputQuiescence = .{},
        closed: std.atomic.Value(bool) = .init(false),
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop(global.io())) |msg| msg.deinit();
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) void {
        self.sendWithEpoch(msg, mutex, self.spsc.input.snapshot());
    }

    pub fn sendWithEpoch(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
        epoch: u64,
    ) void {
        if (self.spsc.closed.load(.acquire)) {
            msg.deinit();
            return;
        }
        const envelope: Envelope = .{ .message = msg, .input_epoch = epoch };
        switch (self.*) {
            .spsc => |*mb| send: {
                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(global.io(), envelope, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    mb.input.fail();
                    msg.deinit();
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock(global.io());
                defer if (mutex) |m| m.lockUncancelable(global.io());
                if (mb.queue.push(global.io(), envelope, .{ .forever = {} }) == 0) {
                    mb.input.fail();
                    msg.deinit();
                }
            },
        }
    }

    /// Stop accepting messages before joining the reader during teardown.
    /// Emptying the queue also releases the surface/reader producers that
    /// may already be blocked on a full queue. They each have at most one
    /// in-flight send; subsequent sends observe closed.
    pub fn close(self: *Mailbox) void {
        self.spsc.closed.store(true, .release);
        self.spsc.input.fail();
        while (self.spsc.queue.pop(global.io())) |msg| msg.deinit();
    }

    /// Nonblocking control request: failure leaves input closed, not ready.
    pub fn quiesce(self: *Mailbox) u64 {
        const mb = &self.spsc;
        const token = mb.input.begin();
        if (token == 0) return 0;
        if (mb.closed.load(.acquire)) return token;
        if (mb.queue.push(global.io(), .{
            .message = .{ .input_barrier = token },
            .input_epoch = mb.input.snapshot(),
        }, .{ .instant = {} }) == 0) _ = mb.input.cancel(token);
        self.notify();
        return token;
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
                v.input.fail();
            },
        }
    }
};

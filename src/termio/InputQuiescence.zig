//! Opt-in PTY input admission and asynchronous writer barrier.
//! Epochs are captured before queueing, including before a potentially blocking
//! send. An old or closed epoch can therefore never become writable on resume.
const InputQuiescence = @This();

const std = @import("std");
const Atomic = std.atomic.Value;

pub const Status = enum(c_int) { invalid, pending, ready, failed };
const Phase = enum(u2) { open, pending, ready, failed };
const max_token = std.math.maxInt(u64) >> 2;

// Process-wide allocation also prevents a token from another surface (including
// a destroyed surface whose address was reused) from authorizing input.
var tokens: Atomic(u64) = .init(0);

epoch: Atomic(u64) = .init(0),
broken: Atomic(bool) = .init(false),

pub fn snapshot(self: *const InputQuiescence) u64 {
    return self.epoch.load(.acquire);
}

pub fn accepts(self: *const InputQuiescence, epoch: u64) bool {
    return phase(epoch) == .open and self.snapshot() == epoch and
        (epoch == 0 or !self.broken.load(.acquire));
}

pub fn isOpen(self: *const InputQuiescence) bool {
    return self.accepts(self.snapshot());
}

/// Called on the surface thread. Zero means token exhaustion; input still
/// closes, permanently. Every other call supersedes any preceding request.
pub fn begin(self: *InputQuiescence) u64 {
    return self.beginWithCounter(&tokens);
}

fn beginWithCounter(self: *InputQuiescence, counter: *Atomic(u64)) u64 {
    const token = allocateToken(counter) orelse {
        self.fail();
        self.epoch.store(@intFromEnum(Phase.failed), .release);
        return 0;
    };
    self.epoch.store(value(token, .pending), .release);
    // Check after publishing so concurrent failure cannot be lost.
    if (self.broken.load(.acquire)) _ = self.cancel(token);
    return token;
}

pub fn status(self: *const InputQuiescence, token: u64) Status {
    const epoch = self.snapshot();
    if (token == 0 or token > max_token or epoch >> 2 != token) return .invalid;
    if (phase(epoch) == .open) return .invalid;
    if (self.broken.load(.acquire)) return .failed;
    return switch (phase(epoch)) {
        .open => .invalid,
        .pending => .pending,
        .ready => .ready,
        .failed => .failed,
    };
}

/// Only the writer thread may publish readiness, after consuming the barrier
/// and observing zero outstanding libxev writes.
pub fn ready(self: *InputQuiescence, token: u64) void {
    if (token == 0 or token > max_token) return;
    if (self.broken.load(.acquire)) {
        _ = self.cancel(token);
        return;
    }
    _ = self.epoch.cmpxchgStrong(
        value(token, .pending),
        value(token, .ready),
        .acq_rel,
        .acquire,
    );
}

pub fn resumeInput(self: *InputQuiescence, token: u64) bool {
    if (token == 0 or token > max_token) return false;
    if (self.broken.load(.acquire)) return false;
    return self.epoch.cmpxchgStrong(
        value(token, .ready),
        value(token, .open),
        .acq_rel,
        .acquire,
    ) == null;
}

/// Cancel without reopening. A later begin can request a new barrier.
pub fn cancel(self: *InputQuiescence, token: u64) bool {
    if (token == 0 or token > max_token) return false;
    var epoch = self.snapshot();
    while (epoch >> 2 == token) {
        switch (phase(epoch)) {
            .open, .failed => return false,
            .pending, .ready => {},
        }
        epoch = self.epoch.cmpxchgWeak(
            epoch,
            value(token, .failed),
            .acq_rel,
            .acquire,
        ) orelse return true;
    }
    return false;
}

/// A writer/transport failure is sticky. Preserve legacy admission until the
/// API is first used, but never allow a subsequent barrier to report success.
pub fn fail(self: *InputQuiescence) void {
    self.broken.store(true, .release);
    var epoch = self.snapshot();
    while (phase(epoch) != .open) {
        epoch = self.epoch.cmpxchgWeak(
            epoch,
            value(epoch >> 2, .failed),
            .acq_rel,
            .acquire,
        ) orelse return;
    }
}

fn allocateToken(counter: *Atomic(u64)) ?u64 {
    var last = counter.load(.monotonic);
    while (last < max_token) {
        last = counter.cmpxchgWeak(last, last + 1, .monotonic, .monotonic) orelse
            return last + 1;
    }
    return null;
}

fn phase(epoch: u64) Phase {
    return @enumFromInt(@as(u2, @truncate(epoch)));
}

fn value(token: u64, p: Phase) u64 {
    return (token << 2) | @intFromEnum(p);
}

test "input quiescence epochs, stale tokens, and closed-generation clipboard" {
    const testing = std.testing;
    var input: InputQuiescence = .{};
    const old_clipboard = input.snapshot();
    try testing.expect(input.accepts(old_clipboard));
    const first = input.begin();
    const gated_clipboard = input.snapshot();
    try testing.expectEqual(.pending, input.status(first));
    try testing.expect(!input.accepts(old_clipboard));
    try testing.expect(!input.accepts(gated_clipboard));
    try testing.expect(!input.resumeInput(first));

    const second = input.begin();
    try testing.expect(second != first);
    input.ready(first);
    try testing.expectEqual(.invalid, input.status(first));
    try testing.expectEqual(.pending, input.status(second));
    input.ready(second);
    try testing.expectEqual(.ready, input.status(second));
    try testing.expect(!input.resumeInput(first));
    try testing.expect(input.resumeInput(second));
    try testing.expect(!input.resumeInput(second));
    try testing.expect(input.isOpen());
    try testing.expect(!input.accepts(old_clipboard));
    try testing.expect(!input.accepts(gated_clipboard));

    var other: InputQuiescence = .{};
    const other_token = other.begin();
    other.ready(other_token);
    try testing.expect(!other.resumeInput(second));
}

test "input quiescence cancellation, failure, and exhaustion fail closed" {
    const testing = std.testing;
    var input: InputQuiescence = .{};
    const first = input.begin();
    try testing.expect(input.cancel(first));
    input.ready(first);
    try testing.expectEqual(.failed, input.status(first));
    try testing.expect(!input.resumeInput(first));
    const second = input.begin();
    input.ready(second);
    input.fail();
    try testing.expectEqual(.failed, input.status(second));
    try testing.expect(!input.resumeInput(second));
    const third = input.begin();
    input.ready(third);
    try testing.expectEqual(.failed, input.status(third));

    var legacy: InputQuiescence = .{};
    legacy.fail();
    try testing.expect(legacy.isOpen());
    const failed = legacy.begin();
    try testing.expectEqual(.failed, legacy.status(failed));

    var counter: Atomic(u64) = .init(max_token - 1);
    var exhausted: InputQuiescence = .{};
    const last = exhausted.beginWithCounter(&counter);
    try testing.expectEqual(max_token, last);
    exhausted.ready(last);
    try testing.expectEqual(0, exhausted.beginWithCounter(&counter));
    try testing.expectEqual(.invalid, exhausted.status(last));
    try testing.expect(!exhausted.isOpen());
    try testing.expectEqual(0, exhausted.beginWithCounter(&counter));

    var resumed: InputQuiescence = .{};
    const consumed = resumed.begin();
    resumed.ready(consumed);
    try testing.expect(resumed.resumeInput(consumed));
    resumed.fail();
    try testing.expectEqual(.invalid, resumed.status(consumed));
    try testing.expect(!resumed.isOpen());
}

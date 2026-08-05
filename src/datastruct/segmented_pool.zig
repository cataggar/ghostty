const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const SegmentedList = @import("segmented_list.zig").SegmentedList;
const testing = std.testing;

/// A data structure where you can get stable (never copied) pointers to
/// a type that automatically grows if necessary. The values can be "put back"
/// but are expected to be put back IN ORDER.
///
/// This is implemented specifically for libuv write requests, since the
/// write requests must have a stable pointer and are guaranteed to be processed
/// in order for a single stream.
///
/// This is NOT thread safe.
pub fn SegmentedPool(comptime T: type, comptime prealloc: usize) type {
    return struct {
        const Self = @This();

        i: usize = 0,
        available: usize = prealloc,
        list: SegmentedList(T, prealloc) = .{ .len = prealloc },

        /// Maps a ring slot to the value that lives in it. Growth has to
        /// reorder the ring (see `grow`), so after the first growth this
        /// mapping is no longer the identity and has to be materialized.
        /// It stays empty until then so that a pool is still usable when
        /// it is initialized without an allocator.
        ring: std.ArrayList(*T) = .empty,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.list.deinit(alloc);
            self.ring.deinit(alloc);
            self.* = undefined;
        }

        /// Get a pointer to the value in ring slot `idx`.
        fn at(self: *Self, idx: usize) *T {
            if (self.ring.items.len > 0) return self.ring.items[idx];
            return self.list.at(idx);
        }

        /// Get the next available value out of the list. This will not
        /// grow the list.
        pub fn get(self: *Self) !*T {
            // Error to not have any
            if (self.available == 0) return error.OutOfValues;

            // The index we grab is just i % len, so we wrap around to the front.
            const i = @mod(self.i, self.list.len);
            self.i +%= 1; // Wrapping addition to swe go back to 0
            self.available -= 1;
            return self.at(i);
        }

        /// Get the next available value out of the list and grow the list
        /// if necessary.
        pub fn getGrow(self: *Self, alloc: Allocator) !*T {
            if (self.available == 0) try self.grow(alloc);
            return try self.get();
        }

        fn grow(self: *Self, alloc: Allocator) !void {
            // We only ever grow when nothing is available, which means every
            // value is checked out and the oldest one of them is the value in
            // the slot the head points at. Rebuilding the ring below relies on
            // that.
            assert(self.available == 0);

            const old_len = self.list.len;
            const new_len = old_len * 2;
            try self.list.growCapacity(alloc, new_len);
            self.list.len = new_len;

            // Rebuild the ring so that the values that are still checked out
            // come first, oldest first, followed by the values we just made
            // room for. Values are put back in the order they were handed out,
            // so once the new values have been handed out the head has to wrap
            // around to the oldest checked out value. Leaving the ring alone
            // and resetting the head to `old_len` would instead wrap it to
            // slot 0, which is only the oldest checked out value when the head
            // happened to be aligned to the start of the ring, and otherwise
            // hands a caller a value that is still in use.
            var ring: std.ArrayList(*T) = .empty;
            errdefer ring.deinit(alloc);
            try ring.ensureTotalCapacityPrecise(alloc, new_len);
            const head = @mod(self.i, old_len);
            for (0..old_len) |n| {
                ring.appendAssumeCapacity(self.at(@mod(head + n, old_len)));
            }
            for (old_len..new_len) |idx| {
                ring.appendAssumeCapacity(self.list.at(idx));
            }

            self.ring.deinit(alloc);
            self.ring = ring;
            self.i = old_len;
            self.available = old_len;
        }

        /// Put a value back. The value put back is expected to be the
        /// in order of get.
        pub fn put(self: *Self) void {
            self.available += 1;
            assert(self.available <= self.list.len);
        }
    };
}

test "SegmentedPool" {
    var list: SegmentedPool(u8, 2) = .{};
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), list.available);

    // Get to capacity
    const v1 = try list.get();
    const v2 = try list.get();
    try testing.expect(v1 != v2);
    try testing.expectError(error.OutOfValues, list.get());

    // Test writing for later
    v1.* = 42;

    // Put a value back
    list.put();
    const temp = try list.get();
    try testing.expect(v1 == temp);
    try testing.expect(temp.* == 42);
    try testing.expectError(error.OutOfValues, list.get());

    // Grow
    const v3 = try list.getGrow(testing.allocator);
    try testing.expect(v1 != v3 and v2 != v3);
    _ = try list.get();
    try testing.expectError(error.OutOfValues, list.get());

    // Put a value back
    list.put();
    try testing.expect(v2 == try list.get());
    try testing.expectError(error.OutOfValues, list.get());
}

test "SegmentedPool: growth does not hand out a checked out value" {
    var pool: SegmentedPool(u8, 2) = .{};
    defer pool.deinit(testing.allocator);

    // Walk the head off of slot 0 so that growth has an order to preserve.
    const v1 = try pool.get();
    const v2 = try pool.get();
    pool.put(); // returns v1, the oldest
    try testing.expectEqual(v1, try pool.get());
    // Checked out, oldest first: v2, v1

    // Grow. Everything handed out so far is still checked out, so the two
    // values this hands out have to be brand new ones.
    const v3 = try pool.getGrow(testing.allocator);
    const v4 = try pool.get();
    try testing.expect(v3 != v1 and v3 != v2);
    try testing.expect(v4 != v1 and v4 != v2 and v4 != v3);
    try testing.expectError(error.OutOfValues, pool.get());
    // Checked out, oldest first: v2, v1, v3, v4

    // One value comes back. Values are put back in the order they were
    // handed out, so that is v2, and v2 is the only value free to hand out.
    pool.put();
    const reused = try pool.get();
    try testing.expectEqual(v2, reused);
}

test "SegmentedPool: never hands out a value that is still checked out" {
    var pool: SegmentedPool(usize, 4) = .{};
    defer pool.deinit(testing.allocator);

    var checked_out: std.ArrayList(*usize) = .empty;
    defer checked_out.deinit(testing.allocator);

    // Hand out two values for every one put back. This is the shape a busy
    // pty write queue has: it forces repeated growth while earlier values are
    // still in flight, and it keeps the ring head away from slot 0.
    for (0..1024) |n| {
        const v = try pool.getGrow(testing.allocator);
        for (checked_out.items) |other| try testing.expect(other != v);
        try checked_out.append(testing.allocator, v);

        if (n % 2 == 0) continue;
        _ = checked_out.orderedRemove(0);
        pool.put();
    }
}

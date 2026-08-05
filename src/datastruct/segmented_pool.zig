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

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.list.deinit(alloc);
            self.* = undefined;
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
            return self.list.at(i);
        }

        /// Get the next available value out of the list and grow the list
        /// if necessary.
        pub fn getGrow(self: *Self, alloc: Allocator) !*T {
            if (self.available == 0) try self.grow(alloc);
            return try self.get();
        }

        fn grow(self: *Self, alloc: Allocator) !void {
            try self.list.growCapacity(alloc, self.list.len * 2);
            self.i = self.list.len;
            self.available = self.list.len;
            self.list.len *= 2;
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
    try testing.expect(v1 == try list.get());
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

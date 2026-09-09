//! Lifetime and admission epoch of an embedded asynchronous clipboard read.
const ClipboardRead = @This();
const std = @import("std");
const apprt = @import("../apprt.zig");
const InputQuiescence = @import("../termio/InputQuiescence.zig");

request: apprt.ClipboardRequest,
input_epoch: u64,
prev: ?*ClipboardRead = null,
next: ?*ClipboardRead = null,

pub const List = @import("../datastruct/main.zig").IntrusiveDoublyLinkedList(ClipboardRead);

pub fn create(
    alloc: std.mem.Allocator,
    list: *List,
    request: apprt.ClipboardRequest,
    epoch: u64,
) !*ClipboardRead {
    const read = try alloc.create(ClipboardRead);
    read.* = .{ .request = request, .input_epoch = epoch };
    list.append(read);
    return read;
}

pub fn destroy(self: *ClipboardRead, alloc: std.mem.Allocator, list: *List) void {
    list.remove(self);
    alloc.destroy(self);
}

pub fn discardStale(
    self: *ClipboardRead,
    alloc: std.mem.Allocator,
    list: *List,
    input: *const InputQuiescence,
) bool {
    if (input.accepts(self.input_epoch)) return false;
    self.destroy(alloc, list);
    return true;
}

pub fn destroyAll(alloc: std.mem.Allocator, list: *List) void {
    while (list.pop()) |read| alloc.destroy(read);
}

test "input quiescence clipboard ownership and stale confirmations" {
    const testing = std.testing;
    var list: List = .{};
    defer destroyAll(testing.allocator, &list);
    var input: InputQuiescence = .{};
    const old = try create(testing.allocator, &list, .paste, input.snapshot());
    try testing.expect(!old.discardStale(testing.allocator, &list, &input));
    const token = input.begin();
    const closed = try create(testing.allocator, &list, .{ .osc_52_read = .standard }, input.snapshot());
    input.ready(token);
    try testing.expect(input.resumeInput(token));
    try testing.expect(old.discardStale(testing.allocator, &list, &input));
    try testing.expect(closed.discardStale(testing.allocator, &list, &input));
    try testing.expect(list.first == null);

    const fresh = try create(testing.allocator, &list, .paste, input.snapshot());
    try testing.expect(!fresh.discardStale(testing.allocator, &list, &input));
    destroyAll(testing.allocator, &list);
    try testing.expect(list.first == null);
}

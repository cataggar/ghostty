const std = @import("std");

pub fn Managed(comptime Item: type, comptime alignment: ?std.mem.Alignment) type {
    const Pool = std.heap.memory_pool.Extra(Item, .{ .alignment = alignment });
    return struct {
        const Self = @This();
        const ItemPtr = *align(Pool.item_alignment.toByteUnits()) Item;
        pub const item_size = Pool.item_size;
        pub const item_alignment = Pool.item_alignment;

        allocator: std.mem.Allocator,
        unmanaged: Pool,

        pub fn initCapacity(allocator: std.mem.Allocator, count: usize) !Self {
            return .{
                .allocator = allocator,
                .unmanaged = try Pool.initCapacity(allocator, count),
            };
        }

        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
        }

        pub fn reset(self: *Self, mode: std.heap.ArenaAllocator.ResetMode) bool {
            return self.unmanaged.reset(self.allocator, mode);
        }

        pub fn create(self: *Self) std.mem.Allocator.Error!ItemPtr {
            return self.unmanaged.create(self.allocator);
        }

        pub fn destroy(self: *Self, item: ItemPtr) void {
            self.unmanaged.destroy(item);
        }
    };
}

const std = @import("std");
const selection = @import("launch_policy_test_selector");
const expected_names = selection.expected_names;
const select = selection.select;

// Keep these declarations in the test root module so Zig collects them,
// while the implementation has one named-module owner shared with the runner.

const TestRecord = struct {
    name: []const u8,
    id: usize,
};

fn testInventory() [expected_names.len]TestRecord {
    var result: [expected_names.len]TestRecord = undefined;
    for (expected_names, 0..) |name, i| result[i] = .{ .name = name, .id = i };
    return result;
}

test "launch policy pure selector accepts exact inventory" {
    var available: [expected_names.len + 2]TestRecord = undefined;
    for (expected_names, 0..) |name, i| {
        available[expected_names.len - i - 1] = .{ .name = name, .id = i };
    }
    available[expected_names.len] = .{ .name = "root.test_0", .id = expected_names.len };
    available[expected_names.len + 1] = .{ .name = "other.test.unrelated", .id = expected_names.len + 1 };

    var selected: [expected_names.len]TestRecord = undefined;
    try select(TestRecord, &available, &selected);
    for (selected, 0..) |entry, i| {
        try std.testing.expectEqualStrings(expected_names[i], entry.name);
        try std.testing.expectEqual(i, entry.id);
    }
}

test "launch policy pure selector rejects incomplete or duplicate inventory" {
    var selected: [expected_names.len]TestRecord = undefined;
    try std.testing.expectError(error.MissingTest, select(TestRecord, &.{}, &selected));
    var available = testInventory();
    try std.testing.expectError(error.MissingTest, select(
        TestRecord,
        available[0 .. available.len - 1],
        &selected,
    ));
    available[available.len - 1] = available[0];
    try std.testing.expectError(error.DuplicateTest, select(TestRecord, &available, &selected));

    var extra: [expected_names.len + 1]TestRecord = undefined;
    const inventory = testInventory();
    @memcpy(extra[0..expected_names.len], &inventory);
    extra[expected_names.len] = extra[0];
    try std.testing.expectError(error.DuplicateTest, select(TestRecord, &extra, &selected));
}

test "launch policy pure selector rejects unreviewed focused tests" {
    var available: [expected_names.len + 1]TestRecord = undefined;
    const inventory = testInventory();
    @memcpy(available[0..expected_names.len], &inventory);
    available[expected_names.len] = .{
        .name = "other.test.launch policy pure unreviewed case",
        .id = expected_names.len,
    };
    var selected: [expected_names.len]TestRecord = undefined;
    try std.testing.expectError(error.UnexpectedFocusedTest, select(TestRecord, &available, &selected));

    available[0] = .{ .name = "renamed.test.launch policy pure preparation provenance", .id = 0 };
    try std.testing.expectError(error.UnexpectedFocusedTest, select(
        TestRecord,
        available[0..expected_names.len],
        &selected,
    ));
}

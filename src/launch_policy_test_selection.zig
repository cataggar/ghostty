const std = @import("std");

pub const filter = "launch policy pure";

/// The compile filter alone also admits unnamed tests. Only these reviewed
/// full names may execute; adding or renaming a focused test requires review
/// and a matching inventory update.
pub const expected_names = [_][]const u8{
    "config.launch.test.launch policy pure preparation provenance",
    "config.launch.test.launch policy pure effective argv validation",
    "config.launch.test.launch policy pure cwd identity and override validation",
    "config.Config.test.launch policy pure config default parsing and invalid value",
    "config.Config.test.launch policy pure config clones and failed normal provenance",
    "config.Config.test.launch policy pure config guarded errors and update admission",
    "config.Config.test.launch policy pure controlled replay ownership and allocation failures",
    "config.Config.test.launch policy pure conditional late opt in rejected",
    "config.Config.test.launch policy pure late opt in allocation failures prohibit fallback",
    "config.Config.test.launch policy pure initial input override survives replay",
    "config.CApi.test.launch policy pure generic C getter",
    "apprt.surface.test.launch policy pure working directory override and inheritance",
    "apprt.surface.test.launch policy pure environment errors never fall back",
    "apprt.surface.test.launch policy pure cwd override allocation failures",
    "termio.Exec.test.launch policy pure authoritative exec admission",
    "termio.Exec.test.launch policy pure controlled login and identity rejection",
    "termio.Exec.test.launch policy pure unsupported platform precedes providers",
    "termio.Exec.test.launch policy pure normal login vectors and mocked hush",
    "termio.Exec.test.launch policy pure successful login argv owns source strings",
    "termio.Exec.test.launch policy pure argv allocation failures never become a shell",
    "termio.Exec.test.launch policy pure environment ownership survives allocation errors",
    "termio.Exec.test.launch policy pure checked child setup and start ownership",
    "termio.Exec.test.launch policy pure child exits before creating a session",
    "launch_policy_test_selection.test.launch policy pure selector accepts exact inventory",
    "launch_policy_test_selection.test.launch policy pure selector rejects incomplete or duplicate inventory",
    "launch_policy_test_selection.test.launch policy pure selector rejects unreviewed focused tests",
};

pub const Error = error{
    EmptyAllowlist,
    InvalidExpectedName,
    DuplicateExpectedName,
    MissingTest,
    DuplicateTest,
    UnexpectedFocusedTest,
};

/// Copies records without calling their bodies. Output is usable only after
/// success; the caller must not publish a partially filled array on error.
pub fn select(
    comptime T: type,
    available: []const T,
    output: *[expected_names.len]T,
) Error!void {
    if (expected_names.len == 0) return error.EmptyAllowlist;
    for (expected_names, 0..) |name, i| {
        if (std.mem.indexOf(u8, name, filter) == null)
            return error.InvalidExpectedName;
        for (expected_names[0..i]) |earlier| {
            if (std.mem.eql(u8, name, earlier))
                return error.DuplicateExpectedName;
        }
    }

    var seen = [_]bool{false} ** expected_names.len;
    var count: usize = 0;
    for (available) |entry| {
        const index = index: {
            for (expected_names, 0..) |name, i| {
                if (std.mem.eql(u8, entry.name, name)) break :index i;
            }
            if (std.mem.indexOf(u8, entry.name, filter) != null)
                return error.UnexpectedFocusedTest;
            continue;
        };
        if (seen[index]) return error.DuplicateTest;
        seen[index] = true;
        count += 1;
        output[index] = entry;
    }
    if (count != expected_names.len) return error.MissingTest;
}

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

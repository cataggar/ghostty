const std = @import("std");
const builtin = @import("builtin");
const standard = @import("standard_test_runner");
const selection = @import("launch_policy_test_selection.zig");

pub const std_options = standard.std_options;
pub const fuzz = standard.fuzz;

var selected: [selection.expected_names.len]std.builtin.TestFn = undefined;

pub fn main(init: std.process.Init.Minimal) void {
    selection.select(std.builtin.TestFn, builtin.test_functions, &selected) catch |err|
        std.process.fatal("launch policy test inventory rejected: {s}", .{@errorName(err)});

    // Publish only a complete, validated inventory, before the standard runner
    // enumerates or executes anything in either server or terminal mode.
    builtin.test_functions = &selected;
    standard.main(init);
}

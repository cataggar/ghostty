const std = @import("std");
const assert = std.debug.assert;
const config = @import("config.zig");

pub const log_level = .warn;

const WidthComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        rows.len = config.num_code_points;
        const width_items = rows.items(.width);
        const wcwidth_zi = inputs.items(.wcwidth_zero_in_grapheme);
        const is_em = inputs.items(.is_emoji_modifier);
        const gbnc = inputs.items(.grapheme_break_no_control);
        const wcwidth_sa = inputs.items(.wcwidth_standalone);
        for (0..config.num_code_points) |i| {
            if (wcwidth_zi[i] and !is_em[i] and gbnc[i] != .prepend) {
                width_items[i] = 0;
            } else {
                width_items[i] = @min(2, wcwidth_sa[i]);
            }
        }
    }
};

const IsSymbolComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        rows.len = config.num_code_points;
        const items = rows.items(.is_symbol);
        const gc_items = inputs.items(.general_category);
        const block_items = inputs.items(.block);
        for (0..config.num_code_points) |i| {
            const block = block_items[i];
            items[i] = gc_items[i] == .other_private_use or
                block == .arrows or
                block == .dingbats or
                block == .emoticons or
                block == .miscellaneous_symbols or
                block == .enclosed_alphanumerics or
                block == .enclosed_alphanumeric_supplement or
                block == .miscellaneous_symbols_and_pictographs or
                block == .transport_and_map_symbols;
        }
    }
};

pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "width", .type = u2 },
    .{ .name = "is_symbol", .type = bool },
});

pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{
        .Impl = WidthComponent,
        .inputs = &.{
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_modifier",
            "grapheme_break_no_control",
        },
        .fields = &.{"width"},
    },
    .{
        .Impl = IsSymbolComponent,
        .inputs = &.{ "block", "general_category" },
        .fields = &.{"is_symbol"},
    },
});

pub const get_components = config.get_components;

pub const tables: []const config.Table = &.{
    .{
        .name = "runtime",
        .fields = &.{
            "is_emoji_presentation",
            "case_folding_full",
        },
    },
    .{
        .name = "buildtime",
        .fields = &.{
            "width",
            "wcwidth_zero_in_grapheme",
            "grapheme_break_no_control",
            "is_symbol",
            "is_emoji_vs_base",
        },
    },
};

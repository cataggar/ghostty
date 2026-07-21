const std = @import("std");
const gdk = @import("gdk");
const gtk = @import("gtk");

pub const ShellLayer = enum(c_uint) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,
};

pub const ShellEdge = enum(c_uint) {
    left = 0,
    right = 1,
    top = 2,
    bottom = 3,
};

pub const KeyboardMode = enum(c_uint) {
    none = 0,
    exclusive = 1,
    on_demand = 2,
};

const c = struct {
    extern fn gtk_layer_is_supported() c_int;
    extern fn gtk_layer_get_protocol_version() c_uint;
    extern fn gtk_layer_get_major_version() c_uint;
    extern fn gtk_layer_get_minor_version() c_uint;
    extern fn gtk_layer_get_micro_version() c_uint;
    extern fn gtk_layer_init_for_window(window: *gtk.Window) void;
    extern fn gtk_layer_set_layer(window: *gtk.Window, layer: ShellLayer) void;
    extern fn gtk_layer_set_anchor(window: *gtk.Window, edge: ShellEdge, anchor_to_edge: c_int) void;
    extern fn gtk_layer_set_margin(window: *gtk.Window, edge: ShellEdge, margin_size: c_int) void;
    extern fn gtk_layer_set_keyboard_mode(window: *gtk.Window, mode: KeyboardMode) void;
    extern fn gtk_layer_set_monitor(window: *gtk.Window, monitor: ?*gdk.Monitor) void;
    extern fn gtk_layer_set_namespace(window: *gtk.Window, name: [*:0]const u8) void;
};

pub fn isSupported() bool {
    return c.gtk_layer_is_supported() != 0;
}

pub fn getProtocolVersion() c_uint {
    return c.gtk_layer_get_protocol_version();
}

pub fn getLibraryVersion() std.SemanticVersion {
    return .{
        .major = c.gtk_layer_get_major_version(),
        .minor = c.gtk_layer_get_minor_version(),
        .patch = c.gtk_layer_get_micro_version(),
    };
}

pub fn initForWindow(window: *gtk.Window) void {
    c.gtk_layer_init_for_window(window);
}

pub fn setLayer(window: *gtk.Window, layer: ShellLayer) void {
    c.gtk_layer_set_layer(window, layer);
}

pub fn setAnchor(window: *gtk.Window, edge: ShellEdge, anchor_to_edge: bool) void {
    c.gtk_layer_set_anchor(window, edge, @intFromBool(anchor_to_edge));
}

pub fn setMargin(window: *gtk.Window, edge: ShellEdge, margin_size: c_int) void {
    c.gtk_layer_set_margin(window, edge, margin_size);
}

pub fn setKeyboardMode(window: *gtk.Window, mode: KeyboardMode) void {
    c.gtk_layer_set_keyboard_mode(window, mode);
}

pub fn setMonitor(window: *gtk.Window, monitor: ?*gdk.Monitor) void {
    c.gtk_layer_set_monitor(window, monitor);
}

pub fn setNamespace(window: *gtk.Window, name: [:0]const u8) void {
    c.gtk_layer_set_namespace(window, name.ptr);
}

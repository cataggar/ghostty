test {
    _ = @import("config/launch.zig");
    _ = @import("config/Config.zig");
    _ = @import("config/CApi.zig");
    _ = @import("apprt/surface.zig");
    _ = @import("termio/Exec.zig");
    _ = @import("launch_policy_test_selection.zig");
}

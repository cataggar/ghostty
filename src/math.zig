/// Matrix type
pub const Mat = [4][4]f32;
pub const F32x4 = @Vector(4, f32);

/// 2D orthographic projection matrix
pub fn ortho2d(left: f32, right: f32, bottom: f32, top: f32) Mat {
    const w = right - left;
    const h = top - bottom;
    return .{
        .{ 2 / w, 0, 0, 0 },
        .{ 0, 2 / h, 0, 0 },
        .{ 0.0, 0.0, -1.0, 0.0 },
        .{ -(right + left) / w, -(top + bottom) / h, 0.0, 1.0 },
    };
}

test "orthographic projection preserves shader matrix byte order" {
    const std = @import("std");
    const matrix = ortho2d(-2, 6, -3, 5);
    const expected: [16]f32 = .{
        0.25, 0,     0,  0,
        0,    0.25,  0,  0,
        0,    0,     -1, 0,
        -0.5, -0.25, 0,  1,
    };
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&matrix));
}

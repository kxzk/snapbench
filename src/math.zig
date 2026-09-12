const rl = @import("rl.zig").c;

pub fn matrixTRS(pos: rl.Vector3, yaw: f32, scale: f32) rl.Matrix {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{
        .m0 = scale * c,
        .m1 = 0,
        .m2 = scale * s,
        .m3 = 0,
        .m4 = 0,
        .m5 = scale,
        .m6 = 0,
        .m7 = 0,
        .m8 = scale * -s,
        .m9 = 0,
        .m10 = scale * c,
        .m11 = 0,
        .m12 = pos.x,
        .m13 = pos.y,
        .m14 = pos.z,
        .m15 = 1,
    };
}

const rl = @import("rl.zig");

pub inline fn matrixScaleTranslate(x: f32, y: f32, z: f32, scale: f32) rl.Matrix {
    return .{
        .m0 = scale, .m1 = 0,     .m2 = 0,     .m3 = 0,
        .m4 = 0,     .m5 = scale, .m6 = 0,     .m7 = 0,
        .m8 = 0,     .m9 = 0,     .m10 = scale,.m11 = 0,
        .m12 = x,    .m13 = y,    .m14 = z,    .m15 = 1,
    };
}

pub inline fn matrixTRS(pos: rl.Vector3, yaw: f32, scale: f32) rl.Matrix {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{
        .m0 = scale * c,  .m1 = 0,     .m2 = scale * s,  .m3 = 0,
        .m4 = 0,          .m5 = scale, .m6 = 0,          .m7 = 0,
        .m8 = scale * -s, .m9 = 0,     .m10 = scale * c, .m11 = 0,
        .m12 = pos.x,     .m13 = pos.y,.m14 = pos.z,     .m15 = 1,
    };
}

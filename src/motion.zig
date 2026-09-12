const std = @import("std");
const rl = @import("rl.zig").c;
const collision = @import("collision.zig");
const world = @import("terrain/world.zig");

pub const degrees_to_radians = std.math.pi / 180.0;

pub const Directions = struct { forward: rl.Vector3, right: rl.Vector3 };

pub fn directions(yaw: f32) Directions {
    const radians = yaw * degrees_to_radians;
    const sine = @sin(radians);
    const cosine = @cos(radians);
    return .{
        .forward = .{ .x = sine, .y = 0, .z = -cosine },
        .right = .{ .x = cosine, .y = 0, .z = sine },
    };
}

pub fn smoothingAlpha(dt: f32) f32 {
    return 1 - @exp(-8 * @max(dt, 0));
}

pub const Drone = struct {
    position: rl.Vector3 = .{ .x = 0, .y = 20, .z = 0 },
    target: rl.Vector3 = .{ .x = 0, .y = 20, .z = 0 },
    yaw: f32 = 0,
    visual_yaw: f32 = 0,
    pitch: f32 = -12,
    velocity: rl.Vector3 = .{ .x = 0, .y = 0, .z = 0 },

    pub fn rotate(self: *Drone, degrees: f32) void {
        self.yaw = @mod(self.yaw + degrees, 360);
    }

    pub fn move(self: *Drone, forward: f32, right: f32, up: f32) void {
        const dirs = directions(self.yaw);
        self.target.x += dirs.forward.x * forward + dirs.right.x * right;
        self.target.z += dirs.forward.z * forward + dirs.right.z * right;
        self.target.y += up;
    }

    pub fn constrain(self: *Drone, terrain: *const world.World) void {
        const edge = world.world_half - collision.drone_radius;
        const target: collision.Vec3 = .{
            .x = std.math.clamp(self.target.x, -edge, edge),
            .y = @max(self.target.y, collision.drone_radius),
            .z = std.math.clamp(self.target.z, -edge, edge),
        };
        self.target = collision.resolveMove(terrain, self.position, target);
    }

    pub fn update(self: *Drone, terrain: *const world.World, dt: f32) void {
        self.constrain(terrain);
        const alpha = smoothingAlpha(dt);
        const proposed = rl.Vector3Lerp(self.position, self.target, alpha);
        const resolved = collision.resolveMove(terrain, self.position, proposed);
        if (dt > 0) self.velocity = rl.Vector3Scale(rl.Vector3Subtract(resolved, self.position), 1 / dt);
        self.position = resolved;
        const yaw_delta = @mod(self.yaw - self.visual_yaw + 180, 360) - 180;
        self.visual_yaw = @mod(self.visual_yaw + yaw_delta * alpha, 360);
    }

    pub fn interpolate(previous: Drone, current: Drone, alpha: f32) Drone {
        var result = current;
        result.position = rl.Vector3Lerp(previous.position, current.position, alpha);
        result.velocity = rl.Vector3Lerp(previous.velocity, current.velocity, alpha);
        const delta = @mod(current.visual_yaw - previous.visual_yaw + 180, 360) - 180;
        result.visual_yaw = previous.visual_yaw + delta * alpha;
        result.pitch = std.math.lerp(previous.pitch, current.pitch, alpha);
        return result;
    }
};

test "movement axes are orthonormal at every heading" {
    for (0..360) |angle| {
        const dirs = directions(@floatFromInt(angle));
        try std.testing.expectApproxEqAbs(@as(f32, 0), rl.Vector3DotProduct(dirs.forward, dirs.right), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f32, 1), rl.Vector3Length(dirs.forward), 0.000001);
    }
}

test "smoothing is frame-rate independent and cannot overshoot after a stall" {
    const fast = 1 - std.math.pow(f32, 1 - smoothingAlpha(1.0 / 144.0), 144);
    const slow = 1 - std.math.pow(f32, 1 - smoothingAlpha(1.0 / 30.0), 30);
    try std.testing.expectApproxEqAbs(fast, slow, 0.00001);
    try std.testing.expect(smoothingAlpha(2) <= 1);
    try std.testing.expectEqual(@as(f32, 0), smoothingAlpha(0));
}

test "yaw wraps and strafing follows the drone heading" {
    var drone: Drone = .{};
    drone.rotate(-315);
    try std.testing.expectEqual(@as(f32, 45), drone.yaw);
    drone.move(0, 1, 0);
    try std.testing.expectApproxEqAbs(drone.target.x, drone.target.z, 0.00001);
}

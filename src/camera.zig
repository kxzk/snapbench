const std = @import("std");
const rl = @import("rl.zig").c;
const motion = @import("motion.zig");
const world = @import("terrain/world.zig");
const collision = @import("collision.zig");

pub const sensor_width = 1280;
pub const sensor_height = 720;
pub const Mode = enum { chase, photo };

pub fn sensor(drone: motion.Drone) rl.Camera3D {
    const pitch = drone.pitch * motion.degrees_to_radians;
    const forward = motion.directions(drone.visual_yaw).forward;
    return .{
        .position = drone.position,
        .target = rl.Vector3Add(drone.position, .{ .x = forward.x * @cos(pitch), .y = @sin(pitch), .z = forward.z * @cos(pitch) }),
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 60,
        .projection = rl.CAMERA_PERSPECTIVE,
    };
}

pub const Rig = struct {
    mode: Mode = .chase,
    distance: f32 = 23,

    pub fn update(self: *Rig, drone: motion.Drone, terrain: *const world.World, dt: f32) rl.Camera3D {
        if (self.mode == .photo) return sensor(drone);
        const forward = motion.directions(drone.visual_yaw).forward;
        const target = rl.Vector3Add(drone.position, .{ .x = 0, .y = 0.6, .z = 0 });
        const direction = rl.Vector3Normalize(.{ .x = -forward.x, .y = 0.42, .z = -forward.z });
        const desired = rl.Vector3Add(target, rl.Vector3Scale(direction, 23));
        const clear = collision.cast(terrain, target, desired, 0.35);
        const available = rl.Vector3Distance(target, clear);
        // Retract immediately at obstacles; ease back out without camera pops.
        self.distance = @min(available, std.math.lerp(self.distance, available, 1 - @exp(-5 * dt)));
        var result = sensor(drone);
        result.position = rl.Vector3Add(target, rl.Vector3Scale(direction, @max(self.distance, 0.1)));
        result.target = target;
        return result;
    }
};

const std = @import("std");
const rl = @import("../rl.zig").c;

pub const Frustum = struct {
    camera: rl.Camera3D,
    forward: rl.Vector3,
    right: rl.Vector3,
    up: rl.Vector3,
    vertical: f32,
    horizontal: f32,

    pub fn init(camera: rl.Camera3D, aspect: f32) Frustum {
        const forward = rl.Vector3Normalize(rl.Vector3Subtract(camera.target, camera.position));
        const right = rl.Vector3Normalize(rl.Vector3CrossProduct(forward, camera.up));
        const tangent = @tan(camera.fovy * std.math.pi / 360);
        return .{ .camera = camera, .forward = forward, .right = right, .up = rl.Vector3CrossProduct(right, forward), .vertical = tangent, .horizontal = tangent * aspect };
    }

    pub fn sphereVisible(self: Frustum, center: rl.Vector3, radius: f32) bool {
        const relative = rl.Vector3Subtract(center, self.camera.position);
        const depth = rl.Vector3DotProduct(relative, self.forward);
        if (depth + radius < 0.1 or depth - radius > 400) return false;
        return @abs(rl.Vector3DotProduct(relative, self.right)) <= depth * self.horizontal + radius * @sqrt(1 + self.horizontal * self.horizontal) and
            @abs(rl.Vector3DotProduct(relative, self.up)) <= depth * self.vertical + radius * @sqrt(1 + self.vertical * self.vertical);
    }
};

test "frustum culls behind camera and retains intersecting bounds" {
    const view = Frustum.init(.{ .position = .{ .x = 0, .y = 0, .z = 0 }, .target = .{ .x = 0, .y = 0, .z = -1 }, .up = .{ .x = 0, .y = 1, .z = 0 }, .fovy = 60, .projection = rl.CAMERA_PERSPECTIVE }, 16.0 / 9.0);
    try std.testing.expect(view.sphereVisible(.{ .x = 0, .y = 0, .z = -10 }, 1));
    try std.testing.expect(!view.sphereVisible(.{ .x = 0, .y = 0, .z = 10 }, 1));
    try std.testing.expect(!view.sphereVisible(.{ .x = 100, .y = 0, .z = -10 }, 1));
    try std.testing.expect(view.sphereVisible(.{ .x = 11, .y = 0, .z = -10 }, 2));
}

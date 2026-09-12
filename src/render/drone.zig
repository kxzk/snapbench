const std = @import("std");
const rl = @import("../rl.zig").c;
const loader = @import("../assets/loader.zig");
const motion = @import("../motion.zig");
const math = @import("../math.zig");

pub const DroneRenderer = struct {
    model: rl.Model,
    rotor_centers: [4]rl.Vector3,

    pub fn init() !DroneRenderer {
        const model = try loader.loadModel("assets/drone.glb");
        errdefer loader.unloadModel(model);
        if (model.meshCount != 6) return error.UnexpectedDroneMeshes;
        var centers: [4]rl.Vector3 = undefined;
        for (&centers, 1..) |*center, mesh| {
            const box = rl.GetMeshBoundingBox(model.meshes[mesh]);
            center.* = rl.Vector3Scale(rl.Vector3Add(box.min, box.max), 0.5);
        }
        return .{ .model = model, .rotor_centers = centers };
    }

    pub fn deinit(self: DroneRenderer) void {
        loader.unloadModel(self.model);
    }

    pub fn draw(self: DroneRenderer, drone: motion.Drone, time: f32) void {
        const directions = motion.directions(drone.visual_yaw);
        const bank = std.math.clamp(-rl.Vector3DotProduct(drone.velocity, directions.right) * 0.013, -0.23, 0.23);
        const pitch = std.math.clamp(rl.Vector3DotProduct(drone.velocity, directions.forward) * 0.009, -0.17, 0.17);
        const tilt = rl.MatrixMultiply(rl.MatrixRotateX(pitch), rl.MatrixRotateZ(bank));
        const transform = rl.MatrixMultiply(tilt, math.matrixTRS(drone.position, drone.visual_yaw * motion.degrees_to_radians, 3));
        for (self.model.meshes[0..@intCast(self.model.meshCount)], 0..) |mesh, index| {
            var mesh_transform = transform;
            if (index >= 1 and index <= 4) {
                const pivot = self.rotor_centers[index - 1];
                const direction: f32 = if (index % 2 == 0) 1 else -1;
                var rotor = rl.MatrixMultiply(rl.MatrixTranslate(-pivot.x, -pivot.y, -pivot.z), rl.MatrixRotateY(time * 85 * direction));
                rotor = rl.MatrixMultiply(rotor, rl.MatrixTranslate(pivot.x, pivot.y, pivot.z));
                mesh_transform = rl.MatrixMultiply(rotor, transform);
            }
            rl.DrawMesh(mesh, self.model.materials[@intCast(self.model.meshMaterial[index])], mesh_transform);
        }
    }
};

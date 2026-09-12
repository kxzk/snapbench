const std = @import("std");
const rl = @import("../rl.zig").c;
const loader = @import("../assets/loader.zig");

pub const chunk_side = 8;
pub const chunk_count = chunk_side * chunk_side;
pub const Instance = extern struct {
    x: f32,
    y: f32,
    z: f32,
    scale: f32,
    yaw: f32 = 0,
    tint: f32 = 1,
    wind: f32 = 0,
    phase: f32 = 0,
};
pub const Range = struct { offset: usize = 0, count: usize = 0 };

pub const Batch = struct {
    model: ?rl.Model = null,
    buffer: c_uint = 0,
    ranges: [chunk_count]Range = .{Range{}} ** chunk_count,
    count: usize = 0,
    animation: [*c]rl.ModelAnimation = null,
    animation_frame: f32 = -1,
    bounds: rl.BoundingBox = undefined,

    pub fn init(path: [:0]const u8, instances: []const Instance, ranges: [chunk_count]Range, animated: bool) !Batch {
        if (instances.len == 0) return .{};
        var batch: Batch = .{ .model = try loader.loadModel(path), .ranges = ranges, .count = instances.len };
        errdefer batch.deinit();
        if (animated) {
            batch.animation = try loader.loadIdleAnimation(path);
            batch.animate(0);
        }
        batch.bounds = rl.GetModelBoundingBox(batch.model.?);
        if (batch.animation != null) {
            var lower: rl.Vector3 = .{ .x = std.math.inf(f32), .y = std.math.inf(f32), .z = std.math.inf(f32) };
            var upper = rl.Vector3Negate(lower);
            for (batch.model.?.meshes[0..@intCast(batch.model.?.meshCount)]) |mesh| {
                const vertices = if (mesh.animVertices != null) mesh.animVertices else mesh.vertices;
                for (0..@intCast(mesh.vertexCount)) |index| {
                    const p: rl.Vector3 = .{ .x = vertices[index * 3], .y = vertices[index * 3 + 1], .z = vertices[index * 3 + 2] };
                    lower = rl.Vector3Min(lower, p);
                    upper = rl.Vector3Max(upper, p);
                }
            }
            batch.bounds = .{ .min = lower, .max = upper };
        }
        batch.buffer = rl.rlLoadVertexBuffer(instances.ptr, @intCast(std.mem.sliceAsBytes(instances).len), true);
        if (batch.buffer == 0) return error.InstanceBufferUnavailable;
        return batch;
    }

    pub fn animate(self: *Batch, time: f32) void {
        if (self.animation == null) return;
        const animation = self.animation[0];
        if (animation.keyframeCount <= 0) return;
        const frame = @mod(@floor(time * 30) * 2, @as(f32, @floatFromInt(animation.keyframeCount)));
        if (frame == self.animation_frame) return;
        rl.UpdateModelAnimation(self.model.?, animation, frame);
        self.animation_frame = frame;
    }

    pub fn deinit(self: *Batch) void {
        if (self.animation != null) rl.UnloadModelAnimations(self.animation, 1);
        if (self.model) |model| loader.unloadModel(model);
        if (self.buffer != 0) rl.rlUnloadVertexBuffer(self.buffer);
        self.* = .{};
    }

    pub fn update(self: *Batch, instances: []const Instance, ranges: [chunk_count]Range) void {
        std.debug.assert(instances.len <= self.count);
        if (instances.len > 0) rl.rlUpdateVertexBuffer(self.buffer, instances.ptr, @intCast(std.mem.sliceAsBytes(instances).len), 0);
        self.count = instances.len;
        self.ranges = ranges;
    }

    pub fn draw(self: *const Batch, shader: loader.InstanceShader, visible: ?*const [chunk_count]bool) void {
        const model = self.model orelse return;
        if (self.count == 0) return;
        for (model.meshes[0..@intCast(model.meshCount)], model.meshMaterial[0..@intCast(model.meshCount)]) |mesh, material_index| {
            const diffuse = model.materials[@intCast(material_index)].maps[rl.MATERIAL_MAP_DIFFUSE];
            const color = rl.ColorNormalize(diffuse.color);
            rl.rlSetUniform(shader.color_location, &color, rl.SHADER_UNIFORM_VEC4, 1);
            rl.rlEnableTexture(diffuse.texture.id);
            _ = rl.rlEnableVertexArray(mesh.vaoId);
            rl.rlEnableVertexBuffer(self.buffer);
            for (self.ranges, 0..) |range, chunk| {
                if (range.count == 0 or (visible != null and !visible.?[chunk])) continue;
                const offset: c_int = @intCast(range.offset * @sizeOf(Instance));
                rl.rlSetVertexAttribute(8, 4, rl.RL_FLOAT, false, @sizeOf(Instance), offset);
                rl.rlSetVertexAttribute(9, 4, rl.RL_FLOAT, false, @sizeOf(Instance), offset + 16);
                inline for (.{ 8, 9 }) |attribute| {
                    rl.rlEnableVertexAttribute(attribute);
                    rl.rlSetVertexAttributeDivisor(attribute, 1);
                }
                if (mesh.indices != null) rl.rlDrawVertexArrayElementsInstanced(0, mesh.triangleCount * 3, null, @intCast(range.count)) else rl.rlDrawVertexArrayInstanced(0, mesh.vertexCount, @intCast(range.count));
            }
        }
    }
};

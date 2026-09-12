const std = @import("std");
const rl = @import("../rl.zig").c;
const world = @import("../terrain/world.zig");
const loader = @import("../assets/loader.zig");
const catalog = @import("../assets/catalog.zig");
const cfg = @import("../config.zig").render;
const instancing = @import("instances.zig");
const Frustum = @import("visibility.zig").Frustum;
const Batch = instancing.Batch;
const Instance = instancing.Instance;
const chunk_count = instancing.chunk_count;
const Allocator = std.mem.Allocator;

fn Lists(comptime count: usize) type {
    return struct {
        items: [count]std.ArrayList(Instance) = .{std.ArrayList(Instance).empty} ** count,
        ranges: [count][chunk_count]instancing.Range = .{.{instancing.Range{}} ** chunk_count} ** count,
        fn deinit(self: *@This(), allocator: Allocator) void {
            for (&self.items) |*list| list.deinit(allocator);
        }
        fn append(self: *@This(), allocator: Allocator, kind: anytype, chunk: usize, instance: Instance) !void {
            const index = @intFromEnum(kind);
            const range = &self.ranges[index][chunk];
            if (range.count == 0) range.offset = self.items[index].items.len;
            range.count += 1;
            try self.items[index].append(allocator, instance);
        }
    };
}

pub const TerrainRenderer = struct {
    shader: loader.InstanceShader,
    blocks: [catalog.block_count]Batch = .{Batch{}} ** catalog.block_count,
    decos: [catalog.deco_count]Batch = .{Batch{}} ** catalog.deco_count,
    creatures: [catalog.creature_count]Batch = .{Batch{}} ** catalog.creature_count,
    shadow: rl.RenderTexture2D,
    light_vp: rl.Matrix = undefined,
    visible_chunks: usize = 0,
    shadow_time: f32 = -1,

    pub fn init(allocator: Allocator, terrain: *const world.World) !TerrainRenderer {
        const shader = try loader.InstanceShader.init();
        var renderer: TerrainRenderer = .{ .shader = shader, .shadow = std.mem.zeroes(rl.RenderTexture2D) };
        errdefer renderer.deinit();
        renderer.shadow.id = rl.rlLoadFramebuffer();
        renderer.shadow.texture.width = 2048;
        renderer.shadow.texture.height = 2048;
        renderer.shadow.depth.id = rl.rlLoadTextureDepth(2048, 2048, false);
        if (renderer.shadow.id == 0 or renderer.shadow.depth.id == 0) return error.ShadowBufferUnavailable;
        rl.rlEnableFramebuffer(renderer.shadow.id);
        rl.rlFramebufferAttach(renderer.shadow.id, renderer.shadow.depth.id, rl.RL_ATTACHMENT_DEPTH, rl.RL_ATTACHMENT_TEXTURE2D, 0);
        const complete = rl.rlFramebufferComplete(renderer.shadow.id);
        rl.rlDisableFramebuffer();
        if (!complete) return error.ShadowBufferIncomplete;
        var blocks: Lists(catalog.block_count) = .{};
        defer blocks.deinit(allocator);
        var decos: Lists(catalog.deco_count) = .{};
        defer decos.deinit(allocator);
        for (0..chunk_count) |chunk| {
            const start_x = (chunk % 8) * 8;
            const start_z = (chunk / 8) * 8;
            for (start_z..start_z + 8) |z| {
                for (start_x..start_x + 8) |x| {
                    const cell = terrain.cells[z][x];
                    const p = world.World.worldPos(x, z);
                    const variation = terrain.variation(x, z);
                    for (0..cell.height) |layer| {
                        if (isBuried(terrain, x, z, layer)) continue;
                        const kind: catalog.BlockType = if (terrain.scenario == .legacy)
                            (if (layer == 0) .grass else cell.block_type)
                        else if (layer + 1 < cell.height) .dirt else cell.block_type;
                        try blocks.append(allocator, kind, chunk, .{
                            .x = p.x,
                            .y = (@as(f32, @floatFromInt(layer)) + 0.5) * world.block_scale,
                            .z = p.z,
                            .scale = 1,
                            .tint = 0.94 + variation * 0.1,
                        });
                    }
                    if (cell.height > 0 and cell.deco_type != .none) {
                        const foliage = switch (cell.deco_type) {
                            .tree, .bamboo, .flowers, .plant, .bush => true,
                            else => false,
                        };
                        try decos.append(allocator, cell.deco_type, chunk, .{
                            .x = p.x,
                            .y = world.cellTopY(cell.height),
                            .z = p.z,
                            .scale = terrain.decorationScale(x, z),
                            .yaw = if (terrain.scenario == .island) variation * std.math.tau else 0,
                            .tint = 0.9 + variation * 0.15,
                            .wind = if (foliage) 1 else 0,
                            .phase = variation * std.math.tau,
                        });
                    }
                }
            }
        }
        for (&renderer.blocks, blocks.items, blocks.ranges, 0..) |*batch, list, ranges, index| {
            if (catalog.blockPath(@enumFromInt(index))) |path| batch.* = try .init(path, list.items, ranges, false);
        }
        for (&renderer.decos, decos.items, decos.ranges, 0..) |*batch, list, ranges, index| {
            if (catalog.decoPath(@enumFromInt(index))) |path| batch.* = try .init(path, list.items, ranges, false);
        }
        try renderer.updateCreatures(terrain);
        var count: usize = 0;
        inline for (.{ &renderer.blocks, &renderer.decos, &renderer.creatures }) |batches| {
            for (batches) |batch| count += batch.count;
        }
        std.log.info("Renderer: {d} instances, {d} GPU bytes, 64 visibility chunks, 2048px shadows", .{ count, count * @sizeOf(Instance) });
        return renderer;
    }

    pub fn deinit(self: *TerrainRenderer) void {
        inline for (.{ &self.blocks, &self.decos, &self.creatures }) |batches| {
            for (batches) |*batch| batch.deinit();
        }
        if (self.shadow.id != 0) rl.rlUnloadFramebuffer(self.shadow.id);
        self.shader.deinit();
    }

    pub fn updateCreatures(self: *TerrainRenderer, terrain: *const world.World) !void {
        for (&self.creatures, 0..) |*batch, index| {
            var instances: [@import("../config.zig").world.animal_count]Instance = undefined;
            var ranges: [chunk_count]instancing.Range = .{instancing.Range{}} ** chunk_count;
            var count: usize = 0;
            for (0..chunk_count) |chunk| {
                for (terrain.creatures[0..terrain.creature_count]) |entry| {
                    const cell = terrain.cells[entry.gz][entry.gx];
                    if (@intFromEnum(cell.creature_type) != index or (entry.gz / 8) * 8 + entry.gx / 8 != chunk) continue;
                    if (ranges[chunk].count == 0) ranges[chunk].offset = count;
                    ranges[chunk].count += 1;
                    const p = world.World.worldPos(entry.gx, entry.gz);
                    instances[count] = .{ .x = p.x, .y = world.cellTopY(cell.height), .z = p.z, .scale = cfg.creature_scale };
                    count += 1;
                }
            }
            if (batch.model == null and count > 0) {
                batch.* = try .init(catalog.creaturePath(@enumFromInt(index)).?, instances[0..count], ranges, terrain.scenario == .island);
            }
            if (batch.model == null) continue;
            if (terrain.scenario == .island) {
                const bounds = batch.bounds;
                const height = catalog.creatureShape(@enumFromInt(index)).height;
                const scale = height / @max(bounds.max.y - bounds.min.y, 0.001);
                for (instances[0..count]) |*instance| {
                    instance.scale = scale;
                    instance.x -= (bounds.max.x + bounds.min.x) * 0.5 * scale;
                    instance.y -= bounds.min.y * scale;
                    instance.z -= (bounds.max.z + bounds.min.z) * 0.5 * scale;
                }
            }
            batch.update(instances[0..count], ranges);
        }
        self.shadow_time = -1;
    }

    pub fn prepare(self: *TerrainRenderer, time: f32, force: bool, drone_renderer: @import("drone.zig").DroneRenderer, drone: @import("../motion.zig").Drone) void {
        // Quantized shadow animation is independent of display refresh rate.
        const shadow_time = @floor(time * 30) / 30;
        if (force or shadow_time != self.shadow_time) {
            for (&self.creatures) |*batch| batch.animate(shadow_time);
            rl.BeginTextureMode(self.shadow);
            rl.ClearBackground(rl.WHITE);
            const light: rl.Camera3D = .{
                .position = .{ .x = -85, .y = 155, .z = -54 },
                .target = .{ .x = 0, .y = 0, .z = 0 },
                .up = .{ .x = 0, .y = 1, .z = 0 },
                .fovy = 184,
                .projection = rl.CAMERA_ORTHOGRAPHIC,
            };
            rl.BeginMode3D(light);
            self.light_vp = rl.MatrixMultiply(rl.rlGetMatrixModelview(), rl.rlGetMatrixProjection());
            self.drawBatches(null, light.position, shadow_time, true);
            drone_renderer.draw(drone, shadow_time);
            rl.EndMode3D();
            rl.EndTextureMode();
            self.shadow_time = shadow_time;
        }
        for (&self.creatures) |*batch| batch.animate(time);
    }

    pub fn render(self: *TerrainRenderer, camera: rl.Camera3D, time: f32, aspect: f32) void {
        const frustum = Frustum.init(camera, aspect);
        var visible: [chunk_count]bool = undefined;
        self.visible_chunks = 0;
        for (&visible, 0..) |*value, chunk| {
            const center: rl.Vector3 = .{
                .x = @as(f32, @floatFromInt(chunk % 8)) * 16 - 56,
                .y = 10,
                .z = @as(f32, @floatFromInt(chunk / 8)) * 16 - 56,
            };
            value.* = frustum.sphereVisible(center, 20);
            if (value.*) self.visible_chunks += 1;
        }
        self.drawBatches(&visible, camera.position, time, false);
    }

    fn drawBatches(self: *const TerrainRenderer, visible: ?*const [chunk_count]bool, camera: rl.Vector3, time: f32, depth: bool) void {
        rl.rlDrawRenderBatchActive();
        rl.rlEnableShader(self.shader.shader.id);
        rl.rlSetUniformMatrix(self.shader.mvp_location, rl.MatrixMultiply(rl.rlGetMatrixModelview(), rl.rlGetMatrixProjection()));
        rl.rlSetUniformMatrix(self.shader.light_location, self.light_vp);
        rl.rlSetUniform(self.shader.time_location, &time, rl.SHADER_UNIFORM_FLOAT, 1);
        rl.rlSetUniform(self.shader.camera_location, &camera, rl.SHADER_UNIFORM_VEC3, 1);
        const depth_pass: f32 = if (depth) 1 else 0;
        rl.rlSetUniform(self.shader.depth_pass_location, &depth_pass, rl.SHADER_UNIFORM_FLOAT, 1);
        const slot: c_int = 10;
        rl.rlActiveTextureSlot(slot);
        // Drivers validate every active sampler even when a branch skips it.
        // Never sample the depth attachment while it is being written.
        rl.rlEnableTexture(if (depth) rl.rlGetTextureIdDefault() else self.shadow.depth.id);
        rl.rlSetUniform(self.shader.shadow_location, &slot, rl.SHADER_UNIFORM_INT, 1);
        rl.rlActiveTextureSlot(0);
        inline for (.{ &self.blocks, &self.decos, &self.creatures }) |batches| {
            for (batches) |*batch| batch.draw(self.shader, visible);
        }
        rl.rlDisableVertexArray();
        rl.rlDisableVertexBuffer();
        rl.rlDisableTexture();
        rl.rlActiveTextureSlot(10);
        rl.rlDisableTexture();
        rl.rlActiveTextureSlot(0);
        rl.rlDisableShader();
    }
};

fn isBuried(terrain: *const world.World, x: usize, z: usize, layer: usize) bool {
    return layer + 1 < terrain.cells[z][x].height and x > 0 and z > 0 and
        x + 1 < world.world_size and z + 1 < world.world_size and
        terrain.cells[z][x - 1].height > layer and terrain.cells[z][x + 1].height > layer and
        terrain.cells[z - 1][x].height > layer and terrain.cells[z + 1][x].height > layer;
}

test "culling keeps exposed terrain and boundary faces" {
    var terrain = world.World.generate(world.hashSeed(42));
    for (&terrain.cells) |*row| for (row) |*cell| {
        cell.height = 3;
    };
    try std.testing.expect(isBuried(&terrain, 32, 32, 0));
    try std.testing.expect(!isBuried(&terrain, 32, 32, 2));
    try std.testing.expect(!isBuried(&terrain, 0, 32, 0));
}

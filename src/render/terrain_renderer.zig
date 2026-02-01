const std = @import("std");
const rl = @import("../rl.zig");
const math = @import("../math.zig");
const world = @import("../terrain/world.zig");
const loader = @import("../assets/loader.zig");
const catalog = @import("../assets/catalog.zig");
const cfg = @import("../config.zig").render;

const identity_matrix = rl.Matrix{
    .m0 = 1, .m4 = 0, .m8 = 0, .m12 = 0,
    .m1 = 0, .m5 = 1, .m9 = 0, .m13 = 0,
    .m2 = 0, .m6 = 0, .m10 = 1, .m14 = 0,
    .m3 = 0, .m7 = 0, .m11 = 0, .m15 = 1,
};

fn TransformBatch(comptime count: usize) type {
    return struct {
        transforms: [count][cfg.max_instances]rl.Matrix = .{.{identity_matrix} ** cfg.max_instances} ** count,
        counts: [count]usize = .{0} ** count,

        fn reset(self: *@This()) void {
            self.counts = .{0} ** count;
        }

        fn push(self: *@This(), type_id: usize, transform: rl.Matrix) void {
            const idx = self.counts[type_id];
            if (idx >= cfg.max_instances) {
                std.log.warn("Instance overflow for type {d}, dropping", .{type_id});
                return;
            }
            self.transforms[type_id][idx] = transform;
            self.counts[type_id] = idx + 1;
        }
    };
}

const BlockBatch = TransformBatch(catalog.block_count);
const DecoBatch = TransformBatch(catalog.deco_count);
const CreatureBatch = TransformBatch(catalog.creature_count);

pub const RenderBatch = struct {
    blocks: BlockBatch = .{},
    decos: DecoBatch = .{},
    creatures: CreatureBatch = .{},

    pub fn reset(self: *RenderBatch) void {
        self.blocks.reset();
        self.decos.reset();
        self.creatures.reset();
    }
};

pub fn collectBatches(w: *const world.World, batch: *RenderBatch) void {
    batch.reset();

    const block_y_offset = world.BLOCK_SCALE * 0.5;
    const grass_type_id = @intFromEnum(catalog.BlockType.grass);
    
    for (0..world.WORLD_SIZE) |z| {
        for (0..world.WORLD_SIZE) |x| {
            const cell = w.cells[z][x];
            if (cell.height == 0) continue;

            const wpos = world.World.worldPos(x, z);
            const base_x = wpos.x;
            const base_z = wpos.z;
            const cell_top_y = world.cellTopY(cell.height);

            // Always place grass block at base
            batch.blocks.push(grass_type_id, math.matrixScaleTranslate(base_x, block_y_offset, base_z, 1.0));
            
            // Stack additional blocks if height > 1
            if (cell.height > 1) {
                const block_type_id = @intFromEnum(cell.block_type);
                for (1..cell.height) |y| {
                    const block_y = @as(f32, @floatFromInt(y)) * world.BLOCK_SCALE + block_y_offset;
                    batch.blocks.push(block_type_id, math.matrixScaleTranslate(base_x, block_y, base_z, 1.0));
                }
            }

            if (cell.deco_type != .none) {
                const transform = math.matrixScaleTranslate(base_x, cell_top_y, base_z, cfg.deco_scale);
                batch.decos.push(@intFromEnum(cell.deco_type), transform);
            }

            if (cell.creature_type != .none) {
                const transform = math.matrixScaleTranslate(base_x, cell_top_y, base_z, cfg.creature_scale);
                batch.creatures.push(@intFromEnum(cell.creature_type), transform);
            }
        }
    }
}

pub fn collectCreatureBatch(w: *const world.World, batch: *RenderBatch) void {
    batch.creatures.reset();

    for (0..w.creature_count) |i| {
        const entry = w.creatures[i];
        const cell = w.cells[entry.gz][entry.gx];
        if (cell.creature_type == .none) continue;

        const wpos = world.World.worldPos(entry.gx, entry.gz);
        const cell_top_y = world.cellTopY(cell.height);
        const transform = math.matrixScaleTranslate(wpos.x, cell_top_y, wpos.z, cfg.creature_scale);
        batch.creatures.push(@intFromEnum(cell.creature_type), transform);
    }
}

pub fn render(cache: *const loader.ModelCache, batch: *const RenderBatch) void {
    loader.setShaderTime(0);

    for (0..catalog.block_count) |i| {
        const count = batch.blocks.counts[i];
        if (count > 0 and cache.blocks[i] != null) {
            drawModelInstanced(cache.blocks[i].?, &batch.blocks.transforms[i], count);
        }
    }

    for (0..catalog.deco_count) |i| {
        const count = batch.decos.counts[i];
        if (count > 0 and cache.decos[i] != null) {
            drawModelInstanced(cache.decos[i].?, &batch.decos.transforms[i], count);
        }
    }

    loader.setShaderTime(@floatCast(rl.GetTime()));

    for (0..catalog.creature_count) |i| {
        const count = batch.creatures.counts[i];
        if (count > 0 and cache.creatures[i] != null) {
            drawModelInstanced(cache.creatures[i].?, &batch.creatures.transforms[i], count);
        }
    }
}

fn drawModelInstanced(model: rl.Model, transforms: *const [cfg.max_instances]rl.Matrix, count: usize) void {
    const mesh_count: usize = @intCast(model.meshCount);
    for (0..mesh_count) |mi| {
        const mat_idx: usize = @intCast(model.meshMaterial[mi]);
        rl.DrawMeshInstanced(model.meshes[mi], model.materials[mat_idx], @ptrCast(transforms), @intCast(count));
    }
}

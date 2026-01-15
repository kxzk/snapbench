const std = @import("std");
const rl = @import("../rl.zig");
const math = @import("../math.zig");
const world = @import("../terrain/world.zig");
const loader = @import("../assets/loader.zig");
const catalog = @import("../assets/catalog.zig");
const cfg = @import("../config.zig").render;

/// Comptime-generic transform batch for GPU instancing.
/// Groups transforms by asset type so each model can be drawn with a single instanced call.
/// The fixed-size arrays avoid allocations; cfg.max_instances caps memory regardless of world size.
fn TransformBatch(comptime count: usize) type {
    return struct {
        transforms: [count][cfg.max_instances]rl.Matrix = undefined,
        counts: [count]usize = .{0} ** count,

        /// Clears all instance counts without deallocating. Called once per frame before collection.
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

/// Aggregates all transform batches for a complete frame render.
/// Separates blocks, decorations, and creatures for independent instanced draws.
pub const RenderBatch = struct {
    blocks: BlockBatch = .{},
    decos: DecoBatch = .{},
    creatures: CreatureBatch = .{},

    /// Resets all sub-batches. Call at start of frame or when world changes.
    pub fn reset(self: *RenderBatch) void {
        self.blocks.reset();
        self.decos.reset();
        self.creatures.reset();
    }
};


/// Iterates the entire world grid and collects transform matrices into batches.
/// For each cell: pushes block transforms for terrain height, then decoration and creature
/// transforms at the cell top. Only needs to run once unless world changes.
pub fn collectBatches(w: *const world.World, batch: *RenderBatch) void {
    batch.reset();

    for (0..world.WORLD_SIZE) |z| {
        for (0..world.WORLD_SIZE) |x| {
            const cell = w.cells[z][x];
            if (cell.height == 0) continue;

            const wpos = world.World.worldPos(x, z);
            const base_x = wpos.x;
            const base_z = wpos.z;
            const cell_top_y = world.cellTopY(cell.height);

            if (cell.height == 1) {
                batch.blocks.push(@intFromEnum(catalog.BlockType.grass), math.matrixScaleTranslate(base_x, 0, base_z, 1.0));
            } else {
                for (1..cell.height) |y| {
                    const block_y = @as(f32, @floatFromInt(y)) * world.BLOCK_SCALE;
                    batch.blocks.push(@intFromEnum(cell.block_type), math.matrixScaleTranslate(base_x, block_y, base_z, 1.0));
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

/// Rebuilds only the creature batch. Use after creature removal instead of full collectBatches.
pub fn collectCreatureBatch(w: *const world.World, batch: *RenderBatch) void {
    batch.creatures.reset();

    for (0..world.WORLD_SIZE) |z| {
        for (0..world.WORLD_SIZE) |x| {
            const cell = w.cells[z][x];
            if (cell.creature_type == .none) continue;

            const wpos = world.World.worldPos(x, z);
            const transform = math.matrixScaleTranslate(wpos.x, world.cellTopY(cell.height), wpos.z, cfg.creature_scale);
            batch.creatures.push(@intFromEnum(cell.creature_type), transform);
        }
    }
}

/// Draws all batched instances using GPU instancing. One draw call per unique model.
/// Iterates block types, then decoration types, then creature types, drawing each
/// with their collected transforms. Skips types with zero instances or unloaded models.
pub fn render(cache: *const loader.ModelCache, batch: *const RenderBatch) void {
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

    for (0..catalog.creature_count) |i| {
        const count = batch.creatures.counts[i];
        if (count > 0 and cache.creatures[i] != null) {
            drawModelInstanced(cache.creatures[i].?, &batch.creatures.transforms[i], count);
        }
    }
}

/// Draws all meshes of a model using GPU instancing with the given transforms.
/// Iterates each mesh in the model and issues a single DrawMeshInstanced call per mesh.
/// This is the hot path - minimizing draw calls is critical for performance.
fn drawModelInstanced(model: rl.Model, transforms: *const [cfg.max_instances]rl.Matrix, count: usize) void {
    const mesh_count: usize = @intCast(model.meshCount);
    for (0..mesh_count) |mi| {
        const mat_idx: usize = @intCast(model.meshMaterial[mi]);
        rl.DrawMeshInstanced(model.meshes[mi], model.materials[mat_idx], @ptrCast(transforms), @intCast(count));
    }
}

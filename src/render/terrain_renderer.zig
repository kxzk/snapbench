const rl = @import("../rl.zig");
const world = @import("../terrain/world.zig");
const loader = @import("../assets/loader.zig");
const catalog = @import("../assets/catalog.zig");

const BLOCK_SCALE: f32 = 1.0;
const DECO_SCALE: f32 = 0.8;
const CREATURE_SCALE: f32 = 1.2;

const MAX_INSTANCES: usize = 2048;

fn TransformBatch(comptime count: usize) type {
    return struct {
        transforms: [count][MAX_INSTANCES]rl.Matrix = undefined,
        counts: [count]usize = .{0} ** count,

        fn reset(self: *@This()) void {
            self.counts = .{0} ** count;
        }

        fn push(self: *@This(), type_id: usize, transform: rl.Matrix) void {
            const idx = self.counts[type_id];
            if (idx < MAX_INSTANCES) {
                self.transforms[type_id][idx] = transform;
                self.counts[type_id] = idx + 1;
            }
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

    var static_instance: RenderBatch = .{};
    pub fn getStatic() *RenderBatch {
        return &static_instance;
    }
};

fn blockTypeForLayer(y: usize) catalog.BlockType {
    return switch (y) {
        0 => .grass,
        1 => .dirt,
        else => .coal,
    };
}

fn makeTransform(x: f32, y: f32, z: f32, scale: f32) rl.Matrix {
    return rl.MatrixMultiply(
        rl.MatrixTranslate(x, y, z),
        rl.MatrixScale(scale, scale, scale),
    );
}

pub fn collectBatches(w: *const world.World, batch: *RenderBatch) void {
    batch.reset();

    for (0..world.WORLD_SIZE) |z| {
        for (0..world.WORLD_SIZE) |x| {
            const cell = w.cells[z][x];
            if (cell.height == 0) continue;

            const wpos = world.World.worldPos(x, z, 0);
            const base_x = wpos.x;
            const base_z = wpos.z;
            const cell_top_y = @as(f32, @floatFromInt(cell.height)) * world.BLOCK_SCALE;

            for (0..cell.height) |y| {
                const layer_block = blockTypeForLayer(y);
                const block_y = @as(f32, @floatFromInt(y + 1)) * world.BLOCK_SCALE;
                const transform = makeTransform(base_x, block_y, base_z, BLOCK_SCALE);
                batch.blocks.push(@intFromEnum(layer_block), transform);
            }

            if (cell.deco_type != .none) {
                const transform = makeTransform(base_x, cell_top_y, base_z, DECO_SCALE);
                batch.decos.push(@intFromEnum(cell.deco_type), transform);
            }

            if (cell.creature_type != .none) {
                const transform = makeTransform(base_x, cell_top_y + CREATURE_SCALE, base_z, CREATURE_SCALE);
                batch.creatures.push(@intFromEnum(cell.creature_type), transform);
            }
        }
    }
}

pub fn renderBatches(batch: *const RenderBatch, cache: *const loader.ModelCache) void {
    for (0..catalog.block_count) |i| {
        const count = batch.blocks.counts[i];
        if (count > 0) {
            if (cache.blocks[i]) |model| {
                drawModelInstanced(model, &batch.blocks.transforms[i], count);
            }
        }
    }

    for (0..catalog.deco_count) |i| {
        const count = batch.decos.counts[i];
        if (count > 0) {
            if (cache.decos[i]) |model| {
                drawModelInstanced(model, &batch.decos.transforms[i], count);
            }
        }
    }

    for (0..catalog.creature_count) |i| {
        const count = batch.creatures.counts[i];
        if (count > 0) {
            if (cache.creatures[i]) |model| {
                drawModelInstanced(model, &batch.creatures.transforms[i], count);
            }
        }
    }
}

fn drawModelInstanced(model: rl.Model, transforms: *const [MAX_INSTANCES]rl.Matrix, count: usize) void {
    const mesh_count: usize = @intCast(model.meshCount);
    for (0..mesh_count) |mi| {
        const mat_idx: usize = @intCast(model.meshMaterial[mi]);
        rl.DrawMeshInstanced(
            model.meshes[mi],
            model.materials[mat_idx],
            @ptrCast(transforms),
            @intCast(count),
        );
    }
}

pub fn render(w: *const world.World, cache: *const loader.ModelCache, batch: *RenderBatch) void {
    collectBatches(w, batch);
    renderBatches(batch, cache);
}

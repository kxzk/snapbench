const std = @import("std");
const noise = @import("noise.zig");
const catalog = @import("../assets/catalog.zig");
const cfg = @import("../config.zig").world;

pub const WORLD_SIZE: usize = cfg.world_size;
pub const BLOCK_SCALE: f32 = cfg.block_scale;
pub const WORLD_HALF: f32 = @as(f32, @floatFromInt(WORLD_SIZE)) * BLOCK_SCALE * 0.5;

/// Returns the Y coordinate of the top surface of a terrain stack.
/// Used for placing creatures and decorations on top of terrain blocks.
/// Height 0 means no terrain (returns 0), height 1+ stacks blocks from y=0.
pub fn cellTopY(height: u8) f32 {
    if (height == 0) return 0;
    return @as(f32, @floatFromInt(height - 1)) * BLOCK_SCALE + 1.0;
}

/// Returns the Y coordinate slightly above the top block for collision purposes.
/// The 0.5 offset places the collision surface at the top face of the block,
/// accounting for the block model being centered at its midpoint.
pub fn cellSurfaceY(height: u8) f32 {
    if (height == 0) return 0;
    return @as(f32, @floatFromInt(height - 1)) * BLOCK_SCALE + 0.5;
}


pub const Cell = packed struct {
    height: u8,
    block_type: catalog.BlockType,
    deco_type: catalog.DecoType,
    creature_type: catalog.CreatureType,
};

pub const World = struct {
    cells: [WORLD_SIZE][WORLD_SIZE]Cell,
    seed: u64,

    /// Procedurally generates an entire world from a seed.
    /// Uses Perlin noise to create "pockets" of elevated terrain, selects block types
    /// based on height and noise variation, places decorations, then spawns creatures.
    /// The seed ensures reproducible worlds for testing and sharing.
    pub fn generate(seed: u64) World {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const perlin = noise.PerlinNoise.init(seed);

        var world: World = undefined;
        world.seed = seed;

        for (0..WORLD_SIZE) |z| {
            for (0..WORLD_SIZE) |x| {
                const fx: f32 = @floatFromInt(x);
                const fz: f32 = @floatFromInt(z);

                const pocket_noise = perlin.sample2D(fx * cfg.pocket_scale + cfg.pocket_offset, fz * cfg.pocket_scale);
                const in_pocket = pocket_noise > cfg.pocket_threshold;

                var height: u8 = cfg.floor_height;
                var block_type: catalog.BlockType = .grass;

                if (in_pocket) {
                    const base_height = perlin.octaveNoise(fx * cfg.height_scale, fz * cfg.height_scale, cfg.height_octaves, 0.5);
                    const normalized = (base_height + 1.0) * 0.5;
                    height = @as(u8, @intFromFloat(normalized * @as(f32, @floatFromInt(cfg.max_terrain_height - 1)))) + 2;
                    block_type = selectTerrainBlock(height, fx, fz, &perlin);
                }

                var deco_type: catalog.DecoType = .none;
                if (height == cfg.floor_height) {
                    deco_type = selectGroundDecoration(fx, fz, &perlin);
                } else if (height >= 3) {
                    deco_type = selectTerrainDecoration(fx, fz, &perlin);
                }

                world.cells[z][x] = .{
                    .height = height,
                    .block_type = block_type,
                    .deco_type = deco_type,
                    .creature_type = .none,
                };
            }
        }

        placeCreatures(&world, rand);

        return world;
    }

    /// Converts grid cell indices to world-space XZ coordinates.
    /// Inverse of collision.worldToGrid. Centers the world around origin (0,0).
    pub fn worldPos(x: usize, z: usize) struct { x: f32, z: f32 } {
        return .{
            .x = @as(f32, @floatFromInt(x)) * BLOCK_SCALE - WORLD_HALF,
            .z = @as(f32, @floatFromInt(z)) * BLOCK_SCALE - WORLD_HALF,
        };
    }
};

/// Selects a block type for elevated terrain based on height and noise.
/// Lower heights get organic materials (dirt, coal, brick, wood planks),
/// higher heights get stone-like materials. Adds visual variety without explicit biomes.
fn selectTerrainBlock(height: u8, x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.BlockType {
    const variation = perlin.sample2D(x * cfg.terrain_var_scale + cfg.terrain_var_offset, z * cfg.terrain_var_scale);

    if (height <= 4) {
        if (variation > 0.3) return .dirt;
        if (variation > 0.1) return .coal;
        if (variation > -0.1) return .brick;
        return .wood_planks;
    }

    if (variation > 0.1) return .grey_bricks;
    return .brick;
}

/// Selects decoration for flat ground-level cells (height=1).
/// Uses noise threshold to cluster decorations naturally, then deterministic
/// position-based selection for type variety. Sparse placement preserves visibility.
fn selectGroundDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * cfg.ground_deco_scale + cfg.ground_deco_offset, z * cfg.ground_deco_scale);

    if (n > 0.3) {
        const v = @as(usize, @intFromFloat(@abs(x * 13 + z * 7))) % 6;
        return switch (v) {
            0 => .bush,
            1 => .bush,
            2 => .flowers,
            3 => .plant,
            4 => .crystal_small,
            else => .none,
        };
    }

    return .none;
}

/// Selects decoration for elevated terrain (height>=3).
/// Elevated areas get trees and bamboo (tall) or crystals (medium).
/// Different noise offset than ground deco ensures independent clustering.
fn selectTerrainDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * cfg.terrain_deco_scale + cfg.terrain_deco_offset, z * cfg.terrain_deco_scale);

    if (n > 0.2) {
        const v = @as(usize, @intFromFloat(@abs(x * 17 + z * 23))) % 2;
        return if (v == 0) .tree else .bamboo;
    }

    if (n > -0.1) {
        return .crystal_big;
    }

    return .none;
}

/// Randomly places a fixed number of creatures on valid grass cells.
/// Creatures can only spawn on grass blocks without existing decorations or creatures.
/// Uses rejection sampling with a max attempt limit to avoid infinite loops on dense maps.
fn placeCreatures(world: *World, rand: std.Random) void {
    var placed: usize = 0;
    var attempts: usize = 0;
    const max_attempts = cfg.animal_count * 30;

    while (placed < cfg.animal_count and attempts < max_attempts) : (attempts += 1) {
        const x = rand.intRangeAtMost(usize, 0, WORLD_SIZE - 1);
        const z = rand.intRangeAtMost(usize, 0, WORLD_SIZE - 1);

        const cell = world.cells[z][x];
        if (cell.block_type != .grass) continue;
        if (cell.creature_type != .none) continue;
        if (cell.deco_type != .none) continue;

        const creature_id: u8 = @intCast(rand.intRangeAtMost(usize, 1, catalog.creature_count - 1));
        world.cells[z][x].creature_type = @enumFromInt(creature_id);
        placed += 1;
    }
}

const std = @import("std");
const noise = @import("noise.zig");
const catalog = @import("../assets/catalog.zig");

pub const WORLD_SIZE: usize = 64;
pub const BLOCK_SCALE: f32 = 2.0;
pub const WORLD_HALF: f32 = @as(f32, @floatFromInt(WORLD_SIZE)) * BLOCK_SCALE * 0.5;

pub fn cellTopY(height: u8) f32 {
    if (height == 0) return 0;
    return @as(f32, @floatFromInt(height - 1)) * BLOCK_SCALE + 1.0;
}

pub fn cellSurfaceY(height: u8) f32 {
    if (height == 0) return 0;
    return @as(f32, @floatFromInt(height - 1)) * BLOCK_SCALE + 0.5;
}

const MAX_TERRAIN_HEIGHT: u8 = 3;
const FLOOR_HEIGHT: u8 = 1;
const ANIMAL_COUNT: usize = 3;

const POCKET_SCALE: f32 = 0.08;
const POCKET_OFFSET: f32 = 500.0;
const POCKET_THRESHOLD: f32 = 0.15;

const HEIGHT_SCALE: f32 = 0.12;
const HEIGHT_OCTAVES: u8 = 3;

const TERRAIN_VAR_SCALE: f32 = 0.25;
const TERRAIN_VAR_OFFSET: f32 = 200.0;

const GROUND_DECO_SCALE: f32 = 0.35;
const GROUND_DECO_OFFSET: f32 = 300.0;

const TERRAIN_DECO_SCALE: f32 = 0.22;
const TERRAIN_DECO_OFFSET: f32 = 700.0;

pub const Cell = packed struct {
    height: u8,
    block_type: catalog.BlockType,
    deco_type: catalog.DecoType,
    creature_type: catalog.CreatureType,
};

pub const World = struct {
    cells: [WORLD_SIZE][WORLD_SIZE]Cell,
    seed: u64,

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

                const pocket_noise = perlin.sample2D(fx * POCKET_SCALE + POCKET_OFFSET, fz * POCKET_SCALE);
                const in_pocket = pocket_noise > POCKET_THRESHOLD;

                var height: u8 = FLOOR_HEIGHT;
                var block_type: catalog.BlockType = .grass;

                if (in_pocket) {
                    const base_height = perlin.octaveNoise(fx * HEIGHT_SCALE, fz * HEIGHT_SCALE, HEIGHT_OCTAVES, 0.5);
                    const normalized = (base_height + 1.0) * 0.5;
                    height = @as(u8, @intFromFloat(normalized * @as(f32, @floatFromInt(MAX_TERRAIN_HEIGHT - 1)))) + 2;
                    block_type = selectTerrainBlock(height, fx, fz, &perlin);
                }

                var deco_type: catalog.DecoType = .none;
                if (height == FLOOR_HEIGHT) {
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

    pub fn worldPos(x: usize, z: usize) struct { x: f32, z: f32 } {
        return .{
            .x = @as(f32, @floatFromInt(x)) * BLOCK_SCALE - WORLD_HALF,
            .z = @as(f32, @floatFromInt(z)) * BLOCK_SCALE - WORLD_HALF,
        };
    }
};

fn selectTerrainBlock(height: u8, x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.BlockType {
    const variation = perlin.sample2D(x * TERRAIN_VAR_SCALE + TERRAIN_VAR_OFFSET, z * TERRAIN_VAR_SCALE);

    if (height <= 4) {
        if (variation > 0.3) return .dirt;
        if (variation > 0.1) return .coal;
        if (variation > -0.1) return .brick;
        return .wood_planks;
    }

    if (variation > 0.1) return .grey_bricks;
    return .brick;
}

fn selectGroundDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * GROUND_DECO_SCALE + GROUND_DECO_OFFSET, z * GROUND_DECO_SCALE);

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

fn selectTerrainDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * TERRAIN_DECO_SCALE + TERRAIN_DECO_OFFSET, z * TERRAIN_DECO_SCALE);

    if (n > 0.2) {
        const v = @as(usize, @intFromFloat(@abs(x * 17 + z * 23))) % 2;
        return if (v == 0) .tree else .bamboo;
    }

    if (n > -0.1) {
        return .crystal_big;
    }

    return .none;
}

fn placeCreatures(world: *World, rand: std.Random) void {
    var placed: usize = 0;
    var attempts: usize = 0;
    const max_attempts = ANIMAL_COUNT * 30;

    while (placed < ANIMAL_COUNT and attempts < max_attempts) : (attempts += 1) {
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

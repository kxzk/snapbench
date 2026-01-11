const std = @import("std");
const noise = @import("noise.zig");
const catalog = @import("../assets/catalog.zig");

pub const WORLD_SIZE: usize = 64;
pub const BLOCK_SCALE: f32 = 2.0;
pub const CHUNK_SIZE: usize = 8;
pub const CHUNK_COUNT: usize = WORLD_SIZE / CHUNK_SIZE;

const MAX_TERRAIN_HEIGHT: u8 = 3;
const FLOOR_HEIGHT: u8 = 1;
const ANIMAL_COUNT: usize = 3;

const POCKET_SCALE: f32 = 0.08;
const POCKET_THRESHOLD: f32 = 0.15;

const HEIGHT_SCALE: f32 = 0.12;
const HEIGHT_OCTAVES: u8 = 3;

fn toFloat(v: usize) f32 {
    return @floatFromInt(v);
}

pub const Cell = packed struct {
    height: u8,
    block_type: catalog.BlockType,
    deco_type: catalog.DecoType,
    creature_type: catalog.CreatureType,
};

pub const Chunk = struct {
    center_x: f32,
    center_z: f32,
    radius_sq: f32,
    start_x: usize,
    start_z: usize,
};

pub const World = struct {
    cells: [WORLD_SIZE][WORLD_SIZE]Cell,
    chunks: [CHUNK_COUNT][CHUNK_COUNT]Chunk,
    seed: u64,

    pub fn generate(seed: u64) World {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const perlin = noise.PerlinNoise.init(seed);

        var world: World = undefined;
        world.seed = seed;

        for (0..WORLD_SIZE) |z| {
            for (0..WORLD_SIZE) |x| {
                const fx = toFloat(x);
                const fz = toFloat(z);

                const pocket_noise = perlin.sample2D(fx * POCKET_SCALE + 500.0, fz * POCKET_SCALE);
                const in_pocket = pocket_noise > POCKET_THRESHOLD;

                var height: u8 = FLOOR_HEIGHT;
                var block_type: catalog.BlockType = .grass;

                if (in_pocket) {
                    const base_height = perlin.octaveNoise(fx * HEIGHT_SCALE, fz * HEIGHT_SCALE, HEIGHT_OCTAVES, 0.5);
                    const normalized = (base_height + 1.0) * 0.5;
                    const terrain_height = @as(u8, @intFromFloat(normalized * @as(f32, @floatFromInt(MAX_TERRAIN_HEIGHT - 1)))) + 2;
                    height = terrain_height;

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
        initChunks(&world);

        return world;
    }

    pub fn worldPos(x: usize, z: usize, height: u8) struct { x: f32, y: f32, z: f32 } {
        const half = toFloat(WORLD_SIZE) * BLOCK_SCALE * 0.5;
        return .{
            .x = toFloat(x) * BLOCK_SCALE - half,
            .y = @as(f32, @floatFromInt(height)) * BLOCK_SCALE,
            .z = toFloat(z) * BLOCK_SCALE - half,
        };
    }
};

fn selectTerrainBlock(height: u8, x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.BlockType {
    const variation = perlin.sample2D(x * 0.25 + 200.0, z * 0.25);

    if (height >= 7) {
        if (variation > 0.1) return .grey_bricks;
        return .brick;
    }
    if (height >= 4) {
        if (variation > 0.2) return .wood_planks;
        return .brick;
    }

    return .grass;
}

fn selectGroundDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * 0.35 + 300.0, z * 0.35);

    if (n > 0.3) {
        const v = @as(usize, @intFromFloat(@abs(x * 13 + z * 7))) % 6;
        return switch (v) {
            0 => .bush,
            1 => .grass_small,
            2 => .flowers,
            3 => .plant,
            4 => .crystal_small,
            else => .grass_tall,
        };
    }

    if (n > 0.0) {
        return .grass_small;
    }

    return .none;
}

fn selectTerrainDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * 0.22 + 700.0, z * 0.22);

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

fn initChunks(world: *World) void {
    const half_world = toFloat(WORLD_SIZE) * BLOCK_SCALE * 0.5;
    const chunk_world_size = toFloat(CHUNK_SIZE) * BLOCK_SCALE;
    const half_chunk = chunk_world_size * 0.5;
    const base_radius_sq = half_chunk * half_chunk * 2.0;

    for (0..CHUNK_COUNT) |cz| {
        for (0..CHUNK_COUNT) |cx| {
            const start_x = cx * CHUNK_SIZE;
            const start_z = cz * CHUNK_SIZE;

            const center_x = toFloat(start_x) * BLOCK_SCALE - half_world + half_chunk;
            const center_z = toFloat(start_z) * BLOCK_SCALE - half_world + half_chunk;

            var max_height: u8 = 0;
            for (start_z..start_z + CHUNK_SIZE) |z| {
                for (start_x..start_x + CHUNK_SIZE) |x| {
                    max_height = @max(max_height, world.cells[z][x].height);
                }
            }

            const height_margin = toFloat(max_height) * BLOCK_SCALE;
            const radius_sq = base_radius_sq + height_margin * height_margin;

            world.chunks[cz][cx] = .{
                .center_x = center_x,
                .center_z = center_z,
                .radius_sq = radius_sq,
                .start_x = start_x,
                .start_z = start_z,
            };
        }
    }
}

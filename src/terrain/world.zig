const std = @import("std");
const noise = @import("noise.zig");
const catalog = @import("../assets/catalog.zig");
const cfg = @import("../config.zig").world;

pub const world_size: usize = cfg.world_size;
pub const block_scale: f32 = cfg.block_scale;
pub const world_half: f32 = @as(f32, @floatFromInt(world_size)) * block_scale * 0.5;
pub const Scenario = enum { legacy, island };

const wyhash_seed_salt = 0x517cc1b727220a95; // Arbitrary but fixed for world compatibility

pub fn hashSeed(world_number: u64) u64 {
    return std.hash.Wyhash.hash(wyhash_seed_salt, std.mem.asBytes(&world_number));
}

/// Returns the Y coordinate of the top surface of a terrain stack.
/// Used for placing creatures and decorations on top of terrain blocks.
/// Height 0 means no terrain (returns 0), height 1+ stacks blocks from y=0.
pub fn cellTopY(height: u8) f32 {
    return @as(f32, @floatFromInt(height)) * block_scale;
}

pub const Cell = packed struct {
    height: u8,
    block_type: catalog.BlockType,
    deco_type: catalog.DecoType,
    creature_type: catalog.CreatureType,
};

const CreatureEntry = struct {
    gx: usize,
    gz: usize,
};

pub const World = struct {
    cells: [world_size][world_size]Cell,
    scenario: Scenario = .legacy,
    seed: u64 = 0,
    creatures: [cfg.animal_count]CreatureEntry = undefined,
    creature_count: usize = 0,
    creatures_dirty: bool = false,

    pub fn create(seed: u64, scenario: Scenario) World {
        return switch (scenario) {
            .legacy => generate(seed),
            .island => @import("island.zig").generate(seed),
        };
    }

    pub fn variation(self: *const World, x: usize, z: usize) f32 {
        if (self.scenario == .legacy) return 0.5;
        const key: [3]u64 = .{ self.seed, x, z };
        const hash = std.hash.Wyhash.hash(71, std.mem.asBytes(&key));
        return @as(f32, @floatFromInt(hash & 0xffff)) / 65535;
    }

    pub fn decorationScale(self: *const World, x: usize, z: usize) f32 {
        return @import("../config.zig").render.deco_scale * (0.8 + 0.4 * self.variation(x, z));
    }

    /// Procedurally generates an entire world from a seed.
    /// Uses Perlin noise to create "pockets" of elevated terrain, selects block types
    /// based on height and noise variation, places decorations, then spawns creatures.
    /// The seed ensures reproducible worlds for testing and sharing.
    pub fn generate(seed: u64) World {
        var prng = std.Random.Xoshiro256.init(seed);
        const rand = prng.random();
        const perlin = noise.PerlinNoise.init(hashSeed(seed));

        var world: World = .{ .cells = undefined };

        for (0..world_size) |z| {
            for (0..world_size) |x| {
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
                    block_type = selectTerrainBlock(fx, fz, &perlin);
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

    /// Converts grid cell indices to world-space XZ coordinates (cell center).
    /// Inverse of collision.worldToGrid. Centers the world around origin (0,0).
    pub fn worldPos(x: usize, z: usize) struct { x: f32, z: f32 } {
        return .{
            .x = @as(f32, @floatFromInt(x)) * block_scale - world_half + block_scale * 0.5,
            .z = @as(f32, @floatFromInt(z)) * block_scale - world_half + block_scale * 0.5,
        };
    }

    pub fn removeCreature(self: *World, gx: usize, gz: usize) void {
        for (self.creatures[0..self.creature_count], 0..) |entry, i| {
            if (entry.gx == gx and entry.gz == gz) {
                self.cells[gz][gx].creature_type = .none;
                self.creatures_dirty = true;
                self.creature_count -= 1;
                self.creatures[i] = self.creatures[self.creature_count];
                return;
            }
        }
    }
};

/// Selects block type for elevated terrain using noise-based variation.
fn selectTerrainBlock(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.BlockType {
    const variation = perlin.sample2D(x * cfg.terrain_var_scale + cfg.terrain_var_offset, z * cfg.terrain_var_scale);
    if (variation > 0.3) return .dirt;
    if (variation > 0.1) return .coal;
    if (variation > -0.1) return .brick;
    return .wood_planks;
}

/// Selects decoration for flat ground-level cells (height=1).
/// Uses noise threshold to cluster decorations naturally, then deterministic
/// position-based selection for type variety. Sparse placement preserves visibility.
fn selectGroundDecoration(x: f32, z: f32, perlin: *const noise.PerlinNoise) catalog.DecoType {
    const n = perlin.sample2D(x * cfg.ground_deco_scale + cfg.ground_deco_offset, z * cfg.ground_deco_scale);

    if (n > 0.3) {
        const v = @as(usize, @intFromFloat(@abs(x * 13 + z * 7))) % 6;
        return switch (v) {
            0, 1 => .bush,
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
    var attempts: usize = 0;
    const max_attempts = cfg.animal_count * 30;

    while (world.creature_count < cfg.animal_count and attempts < max_attempts) : (attempts += 1) {
        const x = rand.intRangeAtMost(usize, 0, world_size - 1);
        const z = rand.intRangeAtMost(usize, 0, world_size - 1);
        tryPlaceCreature(world, rand, x, z);
    }

    // Preserve seeded rejection sampling, with a deterministic fallback if the
    // attempt budget is exhausted. Otherwise a world could be unwinnable.
    for (0..world_size) |z| {
        for (0..world_size) |x| {
            if (world.creature_count == cfg.animal_count) return;
            tryPlaceCreature(world, rand, x, z);
        }
    }
    std.debug.assert(world.creature_count == cfg.animal_count);
}

fn tryPlaceCreature(world: *World, rand: std.Random, x: usize, z: usize) void {
    const cell = &world.cells[z][x];
    if (cell.block_type != .grass or cell.creature_type != .none or cell.deco_type != .none) return;
    cell.creature_type = @enumFromInt(rand.intRangeAtMost(usize, 1, catalog.creature_count - 1));
    world.creatures[world.creature_count] = .{ .gx = x, .gz = z };
    world.creature_count += 1;
}

test "benchmark seeds retain their original terrain and creature placement" {
    const seeds = [_]u64{ 7, 23, 24, 29, 61, 42, 72 };
    const hashes = [_]u64{
        0x12ad6b9f30583df1, 0x7711c450f230ffcf, 0xcb7b5d84787681fa,
        0xe1813ee89332751d, 0x481561cb9d7c6b9c, 0xe0ec84ce6dc11a5d,
        0xbf152a8bddcbda4d,
    };
    for (seeds, hashes) |seed, expected| {
        const terrain = World.generate(hashSeed(seed));
        try std.testing.expectEqual(expected, std.hash.Wyhash.hash(0, std.mem.asBytes(&terrain.cells)));
        try std.testing.expectEqual(cfg.animal_count, terrain.creature_count);
    }
}

test "creature removal is idempotent and preserves its compact index" {
    var terrain = World.generate(hashSeed(42));
    const first = terrain.creatures[0];
    terrain.removeCreature(first.gx, first.gz);
    terrain.creatures_dirty = false;
    terrain.removeCreature(first.gx, first.gz);
    try std.testing.expectEqual(cfg.animal_count - 1, terrain.creature_count);
    try std.testing.expect(!terrain.creatures_dirty);
    for (terrain.creatures[0..terrain.creature_count]) |entry| {
        try std.testing.expect(terrain.cells[entry.gz][entry.gx].creature_type != .none);
    }
}

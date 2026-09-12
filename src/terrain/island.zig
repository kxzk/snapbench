const std = @import("std");
const world = @import("world.zig");
const noise = @import("noise.zig");
const catalog = @import("../assets/catalog.zig");

// Three connected habitats give each seed recognizable navigation landmarks.
const habitats = [_]struct { x: f32, z: f32, species: [3]catalog.CreatureType }{
    .{ .x = -28, .z = -22, .species = .{ .raccoon, .wolf, .cat } },
    .{ .x = 27, .z = -14, .species = .{ .horse, .sheep, .dog } },
    .{ .x = 4, .z = 29, .species = .{ .pig, .cat, .sheep } },
};

pub fn generate(seed: u64) world.World {
    const perlin = noise.PerlinNoise.init(world.hashSeed(seed));
    var terrain: world.World = .{ .cells = undefined, .seed = seed, .scenario = .island };
    for (0..world.world_size) |z| {
        for (0..world.world_size) |x| {
            const p = world.World.worldPos(x, z);
            const radius = @sqrt(p.x * p.x + p.z * p.z);
            const coast = 53 + 5 * perlin.sample2D(p.x * 0.06, p.z * 0.06);
            const variation = terrain.variation(x, z);
            const path = @abs(p.x - 7 * @sin(p.z * 0.075)) < 2.5 or
                @abs(p.z + 18 - 5 * @sin(p.x * 0.065)) < 2.5;
            var clearing = radius < 8;
            for (habitats) |habitat| {
                const dx = p.x - habitat.x;
                const dz = p.z - habitat.z;
                clearing = clearing or dx * dx + dz * dz < 64;
            }
            const ridge = perlin.octaveNoise(p.x * 0.04, p.z * 0.04, 3, 0.5);
            const height: u8 = if (radius > coast) 0 else if (radius > coast - 4) 1 else if (clearing or path) 2 else if (ridge > 0.24) 4 else if (ridge > 0.04) 3 else 2;
            var decoration: catalog.DecoType = .none;
            if (height >= 2 and !clearing and !path) {
                if (p.x < -10 and variation > 0.76) {
                    decoration = .tree;
                } else if (p.z > 8 and variation > 0.86) {
                    decoration = .bamboo;
                } else if (variation > 0.94) {
                    decoration = .bush;
                } else if (variation > 0.87 and p.x > 0) {
                    decoration = .flowers;
                } else if (variation < 0.025) {
                    decoration = .plant;
                }
            }
            terrain.cells[z][x] = .{
                .height = height,
                .block_type = if (height == 0) .air else if (height == 1 or path) .dirt else .grass,
                .deco_type = decoration,
                .creature_type = .none,
            };
        }
    }
    var random = std.Random.Xoshiro256.init(seed);
    for (habitats, 0..) |habitat, index| {
        const x: usize = @intFromFloat((habitat.x + world.world_half) / world.block_scale);
        const z: usize = @intFromFloat((habitat.z + world.world_half) / world.block_scale);
        terrain.cells[z][x].creature_type = habitat.species[random.random().uintLessThan(usize, habitat.species.len)];
        terrain.creatures[index] = .{ .gx = x, .gz = z };
        terrain.creature_count += 1;
    }
    // A small crystal outcrop marks the east ridge without covering every hill.
    for (0..3) |offset| terrain.cells[19 + offset][51].deco_type = .crystal_big;
    return terrain;
}

test "islands are repeatable with open habitats and submerged world edges" {
    for ([_]u64{ 7, 23, 24, 29, 42, 61, 72 }) |seed| {
        const a = generate(seed);
        const b = generate(seed);
        try std.testing.expectEqualDeep(a.cells, b.cells);
        try std.testing.expectEqual(@as(usize, 3), a.creature_count);
        for (a.cells[0]) |cell| try std.testing.expectEqual(@as(u8, 0), cell.height);
        for (a.creatures) |entry| {
            try std.testing.expectEqual(catalog.DecoType.none, a.cells[entry.gz][entry.gx].deco_type);
            try std.testing.expect(a.cells[entry.gz][entry.gx].height >= 2);
        }
    }
}

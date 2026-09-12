const std = @import("std");
const world_mod = @import("terrain/world.zig");
const cfg = @import("config.zig");
const rl = @import("rl.zig").c;
const catalog = @import("assets/catalog.zig");
const collision = @import("collision.zig");

pub const photograph_min_pixels: f32 = 24;
pub const photograph_max_distance: f32 = 40;

pub fn photographable(terrain: *const world_mod.World, gx: usize, gz: usize, camera: rl.Camera3D) bool {
    const cell = terrain.cells[gz][gx];
    if (cell.creature_type == .none) return false;
    const shape = catalog.creatureShape(cell.creature_type);
    const p = world_mod.World.worldPos(gx, gz);
    const center: rl.Vector3 = .{ .x = p.x, .y = world_mod.cellTopY(cell.height) + shape.height * 0.5, .z = p.z };
    const relative = rl.Vector3Subtract(center, camera.position);
    const forward = rl.Vector3Normalize(rl.Vector3Subtract(camera.target, camera.position));
    const depth = rl.Vector3DotProduct(relative, forward);
    if (depth <= 0.5 or rl.Vector3Length(relative) > photograph_max_distance) return false;
    const right = rl.Vector3Normalize(rl.Vector3CrossProduct(forward, camera.up));
    const up = rl.Vector3CrossProduct(right, forward);
    const half_height = depth * @tan(camera.fovy * std.math.pi / 360);
    const half_width = half_height * (1280.0 / 720.0);
    // Keep the entire approximate body within the useful image area.
    if (@abs(rl.Vector3DotProduct(relative, right)) + shape.radius > half_width * 0.95 or
        @abs(rl.Vector3DotProduct(relative, up)) + shape.height * 0.5 > half_height * 0.95 or
        shape.height / (2 * half_height) * 720 < photograph_min_pixels) return false;
    var visible_samples: u8 = 0;
    for ([_]f32{ -0.25, 0, 0.25 }) |offset| {
        var point = center;
        point.y += shape.height * offset;
        if (collision.lineOfSight(terrain, camera.position, point) and
            !creatureOccludes(terrain, gx, gz, camera.position, point)) visible_samples += 1;
    }
    return visible_samples >= 2;
}

fn creatureOccludes(terrain: *const world_mod.World, target_x: usize, target_z: usize, start: rl.Vector3, end: rl.Vector3) bool {
    const ray: rl.Ray = .{ .position = start, .direction = rl.Vector3Normalize(rl.Vector3Subtract(end, start)) };
    const distance = rl.Vector3Distance(start, end);
    for (terrain.creatures[0..terrain.creature_count]) |entry| {
        if (entry.gx == target_x and entry.gz == target_z) continue;
        const cell = terrain.cells[entry.gz][entry.gx];
        const shape = catalog.creatureShape(cell.creature_type);
        const center = world_mod.World.worldPos(entry.gx, entry.gz);
        const base = world_mod.cellTopY(cell.height);
        const hit = rl.GetRayCollisionBox(ray, .{
            .min = .{ .x = center.x - shape.radius, .y = base, .z = center.z - shape.radius },
            .max = .{ .x = center.x + shape.radius, .y = base + shape.height, .z = center.z + shape.radius },
        });
        if (hit.hit and hit.distance < distance) return true;
    }
    return false;
}

pub fn tryPhotograph(terrain: *world_mod.World, camera: rl.Camera3D) bool {
    var selected: ?usize = null;
    var nearest: f32 = std.math.inf(f32);
    for (terrain.creatures[0..terrain.creature_count], 0..) |entry, index| {
        if (!photographable(terrain, entry.gx, entry.gz, camera)) continue;
        const point = world_mod.World.worldPos(entry.gx, entry.gz);
        const cell = terrain.cells[entry.gz][entry.gx];
        const distance = rl.Vector3DistanceSqr(camera.position, .{
            .x = point.x,
            .y = world_mod.cellTopY(cell.height) + catalog.creatureShape(cell.creature_type).height * 0.5,
            .z = point.z,
        });
        if (distance < nearest) {
            selected = index;
            nearest = distance;
        }
    }
    const entry = terrain.creatures[selected orelse return false];
    terrain.removeCreature(entry.gx, entry.gz);
    return true;
}

pub const identify_range: f32 = 5.0;
pub const total_creatures: u8 = cfg.world.animal_count;

pub fn tryIdentify(world: *world_mod.World, x: f32, y: f32, z: f32) bool {
    var selected: ?usize = null;
    var selected_cell: usize = std.math.maxInt(usize);
    for (world.creatures[0..world.creature_count], 0..) |entry, index| {
        const position = world_mod.World.worldPos(entry.gx, entry.gz);
        const base_y = world_mod.cellTopY(world.cells[entry.gz][entry.gx].height);
        const horizontal_range = cfg.render.creature_scale * 0.5 + identify_range;
        if (@abs(x - position.x) > horizontal_range or @abs(z - position.z) > horizontal_range or
            y < base_y - identify_range or y > base_y + cfg.render.creature_scale + identify_range) continue;
        // Keep the original grid-order tie break when two creatures are in range.
        const cell_index = entry.gz * world_mod.world_size + entry.gx;
        if (cell_index < selected_cell) {
            selected = index;
            selected_cell = cell_index;
        }
    }
    const entry = world.creatures[selected orelse return false];
    world.removeCreature(entry.gx, entry.gz);
    return true;
}

pub fn minDistanceToCreature(world: *const world_mod.World, x: f32, y: f32, z: f32) ?f32 {
    if (world.creature_count == 0) return null;
    var min_squared: f32 = std.math.inf(f32);
    for (world.creatures[0..world.creature_count]) |entry| {
        const position = world_mod.World.worldPos(entry.gx, entry.gz);
        const dx = x - position.x;
        const dy = y - world_mod.cellTopY(world.cells[entry.gz][entry.gx].height);
        const dz = z - position.z;
        min_squared = @min(min_squared, dx * dx + dy * dy + dz * dz);
    }
    return @sqrt(min_squared);
}

test "identification keeps the world, remaining count, and game-over state consistent" {
    var world = world_mod.World.generate(world_mod.hashSeed(42));
    try std.testing.expect(!tryIdentify(&world, 0, 100, 0));
    while (world.creature_count > 0) {
        const entry = world.creatures[0];
        const position = world_mod.World.worldPos(entry.gx, entry.gz);
        const base = world_mod.cellTopY(world.cells[entry.gz][entry.gx].height);
        const remaining = world.creature_count;
        try std.testing.expect(tryIdentify(&world, position.x, base, position.z));
        try std.testing.expectEqual(remaining - 1, world.creature_count);
        try std.testing.expect(world.creatures_dirty);
    }
    try std.testing.expect(minDistanceToCreature(&world, 0, 0, 0) == null);
    try std.testing.expect(!tryIdentify(&world, 0, 0, 0));
}

test "photography requires framing distance and line of sight" {
    var terrain = collision.flatWorld();
    terrain.cells[32][32].creature_type = .cat;
    terrain.creatures[0] = .{ .gx = 32, .gz = 32 };
    terrain.creature_count = 1;
    var camera: rl.Camera3D = .{
        .position = .{ .x = 1, .y = 4, .z = 14 },
        .target = .{ .x = 1, .y = 2.8, .z = 1 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 60,
        .projection = rl.CAMERA_PERSPECTIVE,
    };
    try std.testing.expect(photographable(&terrain, 32, 32, camera));
    camera.target.z = 30;
    try std.testing.expect(!photographable(&terrain, 32, 32, camera));
    camera.target.z = 1;
    terrain.cells[35][32].height = 5;
    try std.testing.expect(!photographable(&terrain, 32, 32, camera));
    terrain.cells[35][32].height = 1;
    terrain.cells[36][32].creature_type = .horse;
    terrain.creatures[1] = .{ .gx = 32, .gz = 36 };
    terrain.creature_count = 2;
    try std.testing.expect(!photographable(&terrain, 32, 32, camera));
    terrain.creature_count = 1;
    camera.position.z = 80;
    try std.testing.expect(!photographable(&terrain, 32, 32, camera));
}

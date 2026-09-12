const std = @import("std");
const world = @import("terrain/world.zig");
const catalog = @import("assets/catalog.zig");
const rl = @import("rl.zig").c;

pub const drone_radius: f32 = 0.75;
pub const Vec3 = rl.Vector3;

pub fn worldToGrid(wx: f32, wz: f32) ?struct { x: usize, z: usize } {
    const gx = (wx + world.world_half) / world.block_scale;
    const gz = (wz + world.world_half) / world.block_scale;
    if (!(gx >= 0 and gx < world.world_size and gz >= 0 and gz < world.world_size)) return null;
    return .{ .x = @intFromFloat(gx), .z = @intFromFloat(gz) };
}

fn cylinderIntersects(position: Vec3, radius: f32, x: f32, z: f32, base: f32, shape: catalog.Shape) bool {
    const dx = position.x - x;
    const dz = position.z - z;
    const combined = radius + shape.radius;
    return shape.height > 0 and dx * dx + dz * dz < combined * combined and
        position.y - radius < base + shape.height and position.y + radius > base;
}

pub fn obstructed(terrain: *const world.World, position: Vec3, radius: f32, creatures: bool) bool {
    if (position.y - radius < 0.6) return true; // water and world floor
    const grid = worldToGrid(position.x, position.z) orelse return false;
    const reach: usize = @intFromFloat(@ceil((radius + 1.5) / world.block_scale));
    for (grid.z -| reach..@min(grid.z + reach + 1, world.world_size)) |z| {
        for (grid.x -| reach..@min(grid.x + reach + 1, world.world_size)) |x| {
            const cell = terrain.cells[z][x];
            const center = world.World.worldPos(x, z);
            const top = world.cellTopY(cell.height);
            const dx = @max(@abs(position.x - center.x) - world.block_scale * 0.5, 0);
            const dz = @max(@abs(position.z - center.z) - world.block_scale * 0.5, 0);
            if (cell.height > 0 and dx * dx + dz * dz <= radius * radius and position.y - radius < top) return true;
            const scale = terrain.decorationScale(x, z);
            const shape = catalog.decorationShape(cell.deco_type);
            if (cylinderIntersects(position, radius, center.x, center.z, top, .{
                .radius = shape.radius * scale,
                .height = shape.height * scale,
            })) return true;
        }
    }
    if (creatures) {
        for (terrain.creatures[0..terrain.creature_count]) |entry| {
            const cell = terrain.cells[entry.gz][entry.gx];
            const center = world.World.worldPos(entry.gx, entry.gz);
            if (cylinderIntersects(position, radius, center.x, center.z, world.cellTopY(cell.height), catalog.creatureShape(cell.creature_type))) return true;
        }
    }
    return false;
}

/// Short swept steps prevent tunneling; independent axes permit wall sliding.
pub fn resolveMove(terrain: *const world.World, current: Vec3, target: Vec3) Vec3 {
    const delta = rl.Vector3Subtract(target, current);
    const distance = @max(@abs(delta.x), @max(@abs(delta.y), @abs(delta.z)));
    if (distance < 0.00001) return current;
    const steps: usize = @intFromFloat(@ceil(distance / (drone_radius * 0.5)));
    const increment = rl.Vector3Scale(delta, 1 / @as(f32, @floatFromInt(steps)));
    var result = current;
    for (0..steps) |_| {
        inline for (.{ "y", "x", "z" }) |axis| {
            var candidate = result;
            @field(candidate, axis) += @field(increment, axis);
            if (!obstructed(terrain, candidate, drone_radius, true)) result = candidate;
        }
    }
    return result;
}

/// Conservative sphere sweep shared by the camera boom and photography rays.
pub fn cast(terrain: *const world.World, start: Vec3, end: Vec3, radius: f32) Vec3 {
    const distance = rl.Vector3Distance(start, end);
    const steps: usize = @intFromFloat(@ceil(distance / 0.2));
    if (steps == 0) return start;
    var clear = start;
    for (1..steps + 1) |step| {
        const point = rl.Vector3Lerp(start, end, @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps)));
        if (obstructed(terrain, point, radius, false) or canopyObstructed(terrain, point, radius)) break;
        clear = point;
    }
    return clear;
}

// Soft foliage permits drone movement, but still hides subjects and obstructs
// the camera. An oriented ellipsoid approximates the tree's visible crown.
fn canopyObstructed(terrain: *const world.World, point: Vec3, radius: f32) bool {
    const grid = worldToGrid(point.x, point.z) orelse return false;
    for (grid.z -| 3..@min(grid.z + 4, world.world_size)) |z| {
        for (grid.x -| 3..@min(grid.x + 4, world.world_size)) |x| {
            const cell = terrain.cells[z][x];
            if (cell.deco_type != .tree) continue;
            const scale = terrain.decorationScale(x, z);
            const base = world.cellTopY(cell.height);
            if (point.y + radius < base + 3.5 * scale or point.y - radius > base + 7.7 * scale) continue;
            const center = world.World.worldPos(x, z);
            const yaw = if (terrain.scenario == .island) terrain.variation(x, z) * std.math.tau else 0;
            const dx = point.x - center.x;
            const dz = point.z - center.z;
            const local_x = (dx * @cos(yaw) - dz * @sin(yaw)) / (4.4 * scale + radius);
            const local_z = (dx * @sin(yaw) + dz * @cos(yaw)) / (2.3 * scale + radius);
            if (local_x * local_x + local_z * local_z < 1) return true;
        }
    }
    return false;
}

pub fn lineOfSight(terrain: *const world.World, start: Vec3, end: Vec3) bool {
    return rl.Vector3Distance(cast(terrain, start, end, 0.02), end) < 0.1;
}

pub fn flatWorld() world.World {
    return .{ .cells = .{.{world.Cell{
        .height = 1,
        .block_type = .grass,
        .deco_type = .none,
        .creature_type = .none,
    }} ** world.world_size} ** world.world_size };
}

test "grid conversion rejects nonfinite and outside positions" {
    try std.testing.expect(worldToGrid(world.world_half, 0) == null);
    try std.testing.expect(worldToGrid(-world.world_half - 1, 0) == null);
    try std.testing.expect(worldToGrid(std.math.nan(f32), 0) == null);
    try std.testing.expect(worldToGrid(std.math.inf(f32), 0) == null);
    for (0..world.world_size) |index| {
        const position = world.World.worldPos(index, index);
        try std.testing.expectEqual(index, worldToGrid(position.x, position.z).?.x);
    }
}

test "swept movement cannot tunnel through terrain and slides along walls" {
    var terrain = flatWorld();
    for (&terrain.cells) |*row| row[32].height = 3;
    const result = resolveMove(&terrain, .{ .x = -4, .y = 3, .z = 0 }, .{ .x = 4, .y = 3, .z = 4 });
    try std.testing.expect(result.x <= -drone_radius);
    try std.testing.expectApproxEqAbs(@as(f32, 4), result.z, 0.0001);
}

test "trees collide at their trunks and descending does not snap to canopy height" {
    var terrain = flatWorld();
    terrain.cells[32][32].deco_type = .tree;
    try std.testing.expect(obstructed(&terrain, .{ .x = 1, .y = 4, .z = 1 }, drone_radius, true));
    try std.testing.expect(!obstructed(&terrain, .{ .x = -0.5, .y = 4, .z = 1 }, drone_radius, true));
    const result = resolveMove(&terrain, .{ .x = -0.5, .y = 5, .z = 1 }, .{ .x = -0.5, .y = 2, .z = 1 });
    try std.testing.expect(result.y >= 2 + drone_radius and result.y < 3.2);
}

test "camera and photograph rays stop at terrain" {
    var terrain = flatWorld();
    terrain.cells[32][32].height = 5;
    const start: Vec3 = .{ .x = -5, .y = 4, .z = 1 };
    const end: Vec3 = .{ .x = 5, .y = 4, .z = 1 };
    try std.testing.expect(!lineOfSight(&terrain, start, end));
    try std.testing.expect(cast(&terrain, start, end, 0.3).x < 0);
}

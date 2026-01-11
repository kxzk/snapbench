const world = @import("terrain/world.zig");
const catalog = @import("assets/catalog.zig");

pub const DRONE_RADIUS: f32 = 1.5;
pub const CREATURE_RADIUS: f32 = 1.0;
pub const CREATURE_HEIGHT: f32 = 2.0;

pub fn worldToGrid(wx: f32, wz: f32) ?struct { x: usize, z: usize } {
    const gx = (wx + world.WORLD_HALF) / world.BLOCK_SCALE;
    const gz = (wz + world.WORLD_HALF) / world.BLOCK_SCALE;

    if (gx < 0 or gz < 0) return null;
    const ix = @as(usize, @intFromFloat(gx));
    const iz = @as(usize, @intFromFloat(gz));
    if (ix >= world.WORLD_SIZE or iz >= world.WORLD_SIZE) return null;

    return .{ .x = ix, .z = iz };
}

pub fn getBaseTerrainHeight(w: *const world.World, wx: f32, wz: f32) f32 {
    const grid = worldToGrid(wx, wz) orelse return 0;
    const cell = w.cells[grid.z][grid.x];
    return world.cellSurfaceY(cell.height);
}

pub fn getTerrainHeight(w: *const world.World, wx: f32, wz: f32) f32 {
    const grid = worldToGrid(wx, wz) orelse return 0;
    const cell = w.cells[grid.z][grid.x];
    return world.cellSurfaceY(cell.height) + catalog.decoHeight(cell.deco_type);
}

pub fn checkCreatureCollision(w: *const world.World, x: f32, y: f32, z: f32) bool {
    const grid = worldToGrid(x, z) orelse return false;

    const start_x = grid.x -| 1;
    const start_z = grid.z -| 1;
    const end_x = @min(grid.x + 2, world.WORLD_SIZE);
    const end_z = @min(grid.z + 2, world.WORLD_SIZE);

    for (start_z..end_z) |gz| {
        for (start_x..end_x) |gx| {
            if (creatureCylinderOverlap(w, gx, gz, x, y, z)) return true;
        }
    }
    return false;
}

pub const Vec3 = struct { x: f32, y: f32, z: f32 };

pub fn resolveMove(w: *const world.World, current: Vec3, target: Vec3) Vec3 {
    var result = target;

    const terrain_with_deco = getTerrainHeight(w, target.x, target.z);
    if (terrain_with_deco > current.y - DRONE_RADIUS) {
        result.x = current.x;
        result.z = current.z;
    }

    if (checkCreatureCollision(w, result.x, result.y, result.z)) {
        result = current;
    }

    const floor = getBaseTerrainHeight(w, result.x, result.z);
    result.y = @max(result.y, floor + DRONE_RADIUS);

    return result;
}

fn creatureCylinderOverlap(w: *const world.World, gx: usize, gz: usize, drone_x: f32, drone_y: f32, drone_z: f32) bool {
    const cell = w.cells[gz][gx];
    if (cell.creature_type == .none) return false;

    const wpos = world.World.worldPos(gx, gz);
    const creature_y = world.cellTopY(cell.height);

    const dx = drone_x - wpos.x;
    const dz = drone_z - wpos.z;
    const dist_xz_sq = dx * dx + dz * dz;
    const combined_radius = DRONE_RADIUS + CREATURE_RADIUS;
    if (dist_xz_sq >= combined_radius * combined_radius) return false;

    const drone_bottom = drone_y - DRONE_RADIUS;
    const drone_top = drone_y + DRONE_RADIUS;
    const creature_top = creature_y + CREATURE_HEIGHT;

    return drone_bottom < creature_top and drone_top > creature_y;
}

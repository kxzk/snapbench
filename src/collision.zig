const world = @import("terrain/world.zig");
const catalog = @import("assets/catalog.zig");

pub const DRONE_RADIUS: f32 = 0.75;
pub const CREATURE_RADIUS: f32 = 1.0;
pub const CREATURE_HEIGHT: f32 = 2.0;

/// Converts world-space XZ coordinates to grid cell indices.
/// Returns null if the position is outside the world bounds.
/// The grid origin (0,0) maps to world position (-WORLD_HALF, -WORLD_HALF).
pub inline fn worldToGrid(wx: f32, wz: f32) ?struct { x: usize, z: usize } {
    const gx = (wx + world.WORLD_HALF) / world.BLOCK_SCALE;
    const gz = (wz + world.WORLD_HALF) / world.BLOCK_SCALE;

    if (gx < 0 or gz < 0) return null;
    const ix = @as(usize, @intFromFloat(gx));
    const iz = @as(usize, @intFromFloat(gz));
    if (ix >= world.WORLD_SIZE or iz >= world.WORLD_SIZE) return null;

    return .{ .x = ix, .z = iz };
}

/// Returns the terrain surface height at a world position, ignoring decorations.
/// Used for floor collision to prevent the drone from clipping through terrain blocks.
pub fn getBaseTerrainHeight(w: *const world.World, wx: f32, wz: f32) f32 {
    const grid = worldToGrid(wx, wz) orelse return 0;
    const cell = w.cells[grid.z][grid.x];
    return world.cellTopY(cell.height);
}

/// Returns the effective collision height at a world position, including decoration height.
/// Trees and other tall decorations extend the collision surface upward.
pub fn getTerrainHeight(w: *const world.World, wx: f32, wz: f32) f32 {
    const grid = worldToGrid(wx, wz) orelse return 0;
    const cell = w.cells[grid.z][grid.x];
    return world.cellTopY(cell.height) + catalog.decoHeight(cell.deco_type);
}

/// Checks if the drone at position (x,y,z) collides with any creature.
/// Samples a 3x3 neighborhood of grid cells to catch creatures near cell boundaries.
/// Creatures are treated as vertical cylinders for collision purposes.
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

/// Resolves a proposed movement from current to target position, handling collisions.
/// Rejects entire move if target hits a creature, then blocks XZ if terrain obstructs,
/// finally enforces minimum floor clearance. Returns the valid position.
pub fn resolveMove(w: *const world.World, current: Vec3, target: Vec3) Vec3 {
    if (checkCreatureCollision(w, target.x, target.y, target.z)) {
        return current;
    }

    var result = target;

    // Cache grid lookup for target position - used twice below
    const target_grid = worldToGrid(target.x, target.z);
    
    var terrain_with_deco: f32 = 0;
    if (target_grid) |grid| {
        const cell = w.cells[grid.z][grid.x];
        terrain_with_deco = world.cellTopY(cell.height) + catalog.decoHeight(cell.deco_type);
    }
    if (terrain_with_deco > current.y - DRONE_RADIUS) {
        result.x = current.x;
        result.z = current.z;
        // XZ changed, need to recalculate floor for current position
        var floor: f32 = 0;
        if (worldToGrid(result.x, result.z)) |grid| {
            const cell = w.cells[grid.z][grid.x];
            floor = world.cellTopY(cell.height);
        }
        result.y = @max(result.y, floor + DRONE_RADIUS);
    } else {
        // XZ same as target, reuse target_grid for floor calculation
        var floor: f32 = 0;
        if (target_grid) |grid| {
            const cell = w.cells[grid.z][grid.x];
            floor = world.cellTopY(cell.height);
        }
        result.y = @max(result.y, floor + DRONE_RADIUS);
    }

    return result;
}

/// Tests cylinder-sphere overlap between a creature at grid (gx,gz) and the drone.
/// First checks XZ distance (combined radii), then checks Y overlap between
/// the drone's spherical bounds and the creature's cylindrical height.
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

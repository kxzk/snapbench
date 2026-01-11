const world = @import("terrain/world.zig");
const catalog = @import("assets/catalog.zig");

pub const DRONE_RADIUS: f32 = 0.0;

pub fn worldToGrid(wx: f32, wz: f32) ?struct { x: usize, z: usize } {
    const half = @as(f32, @floatFromInt(world.WORLD_SIZE)) * world.BLOCK_SCALE * 0.5;
    const gx = (wx + half) / world.BLOCK_SCALE;
    const gz = (wz + half) / world.BLOCK_SCALE;

    if (gx < 0 or gz < 0) return null;
    const ix = @as(usize, @intFromFloat(gx));
    const iz = @as(usize, @intFromFloat(gz));
    if (ix >= world.WORLD_SIZE or iz >= world.WORLD_SIZE) return null;

    return .{ .x = ix, .z = iz };
}

pub fn getTerrainHeight(w: *const world.World, wx: f32, wz: f32) f32 {
    const grid = worldToGrid(wx, wz) orelse return 0;
    const cell = w.cells[grid.z][grid.x];
    const base = @as(f32, @floatFromInt(cell.height)) * world.BLOCK_SCALE;
    return base + catalog.decoHeight(cell.deco_type);
}

pub fn checkCollision(w: *const world.World, x: f32, y: f32, z: f32) bool {
    const terrain_height = getTerrainHeight(w, x, z);
    return y - DRONE_RADIUS < terrain_height;
}

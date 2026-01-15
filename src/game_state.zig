const std = @import("std");
const world_mod = @import("terrain/world.zig");
const collision = @import("collision.zig");
const cfg = @import("config.zig").world;
const render_cfg = @import("config.zig").render;

pub const IDENTIFY_RANGE: f32 = 5.0;
pub const TOTAL_CREATURES: u8 = cfg.animal_count;

pub const GameState = struct {
    creatures_found: u8 = 0,
    game_over: bool = false,

    pub fn remaining(self: GameState) u8 {
        return TOTAL_CREATURES - self.creatures_found;
    }
};

pub fn tryIdentify(world: *world_mod.World, state: *GameState, drone_x: f32, drone_y: f32, drone_z: f32) bool {
    const grid = collision.worldToGrid(drone_x, drone_z) orelse return false;

    const search_radius = 3;
    const start_x = grid.x -| search_radius;
    const start_z = grid.z -| search_radius;
    const end_x = @min(grid.x + search_radius + 1, world_mod.WORLD_SIZE);
    const end_z = @min(grid.z + search_radius + 1, world_mod.WORLD_SIZE);

    for (start_z..end_z) |gz| {
        for (start_x..end_x) |gx| {
            if (checkAndRemoveCreature(world, gx, gz, drone_x, drone_y, drone_z)) {
                state.creatures_found += 1;
                if (state.creatures_found >= TOTAL_CREATURES) {
                    state.game_over = true;
                }
                return true;
            }
        }
    }

    return false;
}

fn checkAndRemoveCreature(world: *world_mod.World, gx: usize, gz: usize, drone_x: f32, drone_y: f32, drone_z: f32) bool {
    const cell = &world.cells[gz][gx];
    if (cell.creature_type == .none) return false;

    const wpos = world_mod.World.worldPos(gx, gz);
    const half_xz = render_cfg.creature_scale * 0.5 + IDENTIFY_RANGE;
    const base_y = world_mod.cellTopY(cell.height);

    // AABB is intentionally more lenient than collision cylinder - helps LLM positioning
    const in_range = @abs(drone_x - wpos.x) <= half_xz and
        @abs(drone_z - wpos.z) <= half_xz and
        drone_y >= base_y - IDENTIFY_RANGE and
        drone_y <= base_y + render_cfg.creature_scale + IDENTIFY_RANGE;

    if (!in_range) return false;

    cell.creature_type = .none;
    return true;
}

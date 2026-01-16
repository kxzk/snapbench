// Offsets separate noise sample domains to avoid correlation between terrain features
pub const WorldConfig = struct {
    pocket_scale: f32 = 0.08,
    pocket_offset: f32 = 500.0,
    pocket_threshold: f32 = 0.15,

    height_scale: f32 = 0.12,
    height_octaves: u8 = 3,

    terrain_var_scale: f32 = 0.25,
    terrain_var_offset: f32 = 200.0,

    ground_deco_scale: f32 = 0.35,
    ground_deco_offset: f32 = 300.0,

    terrain_deco_scale: f32 = 0.22,
    terrain_deco_offset: f32 = 700.0,

    world_size: usize = 64,
    block_scale: f32 = 2.0,
    max_terrain_height: u8 = 3,
    floor_height: u8 = 1,
    animal_count: usize = 3,
};

pub const RenderConfig = struct {
    deco_scale: f32 = 0.8,
    creature_scale: f32 = 3.0,
    max_instances: usize = 8192,
};

pub const world = WorldConfig{};
pub const render = RenderConfig{};

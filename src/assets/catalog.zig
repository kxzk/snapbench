pub const BlockType = enum(u8) {
    air = 0,
    grass,
    dirt,
    coal,
    snow,
    diamond,
    crystal,
    brick,
    wood_planks,
    grey_bricks,
};

pub const DecoType = enum(u8) {
    none = 0,
    tree,
    bamboo,
    flowers,
    plant,
    bush,
    crystal_small,
    crystal_big,
};

pub const CreatureType = enum(u8) {
    none = 0,
    cat,
    dog,
    horse,
    pig,
    raccoon,
    sheep,
    wolf,
};

// All seven authored GLBs order clips Death, Headbutt, Idle, ... . raylib's
// 32-byte name field truncates their common prefix before the clip name.
// bench/test_assets.py verifies this catalogue contract against the source GLBs.
pub const creature_idle_clip = 2;

/// Returns the asset file path for a block type, or null for air (no model).
/// Paths are null-terminated for direct use with C APIs (raylib).
pub fn blockPath(t: BlockType) ?[:0]const u8 {
    return switch (t) {
        .air => null,
        .grass => "assets/grass-block.glb",
        .dirt => "assets/dirt-block.glb",
        .coal => "assets/coal-block.glb",
        .snow => "assets/snow-block.glb",
        .diamond => "assets/diamond-block.glb",
        .crystal => "assets/crystal-block.glb",
        .brick => "assets/brick-block.glb",
        .wood_planks => "assets/wood-planks-block.glb",
        .grey_bricks => "assets/grey-bricks.glb",
    };
}

/// Returns the asset file path for a decoration type, or null for none.
pub fn decoPath(t: DecoType) ?[:0]const u8 {
    return switch (t) {
        .none => null,
        .tree => "assets/tree.glb",
        .bamboo => "assets/bamboo.glb",
        .flowers => "assets/flowers.glb",
        .plant => "assets/plant.glb",
        .bush => "assets/bush.glb",
        .crystal_small => "assets/crystal.glb",
        .crystal_big => "assets/big-crystal.glb",
    };
}

/// Returns the asset file path for a creature type, or null for none.
pub fn creaturePath(t: CreatureType) ?[:0]const u8 {
    return switch (t) {
        .none => null,
        .cat => "assets/cat.glb",
        .dog => "assets/dog.glb",
        .horse => "assets/horse.glb",
        .pig => "assets/pig.glb",
        .raccoon => "assets/raccoon.glb",
        .sheep => "assets/sheep.glb",
        .wolf => "assets/wolf.glb",
    };
}

pub const Shape = struct { radius: f32, height: f32 };

/// Unscaled asset dimensions. Tree collision covers the trunk, allowing flight
/// through the soft canopy; small foliage does not act as an invisible wall.
pub fn decorationShape(t: DecoType) Shape {
    return switch (t) {
        .none, .flowers, .plant => .{ .radius = 0, .height = 0 },
        .tree => .{ .radius = 0.38, .height = 7.7 },
        .bamboo => .{ .radius = 0.38, .height = 1.7 },
        .bush => .{ .radius = 1.4, .height = 1.9 },
        .crystal_small => .{ .radius = 0.4, .height = 0.9 },
        .crystal_big => .{ .radius = 0.8, .height = 1.65 },
    };
}

pub fn creatureShape(t: CreatureType) Shape {
    return switch (t) {
        .none => .{ .radius = 0, .height = 0 },
        .cat => .{ .radius = 0.75, .height = 1.6 },
        .dog, .wolf => .{ .radius = 1, .height = 2 },
        .horse => .{ .radius = 1.4, .height = 3 },
        .pig, .sheep => .{ .radius = 1, .height = 1.8 },
        .raccoon => .{ .radius = 0.85, .height = 1.6 },
    };
}

pub const block_count = @typeInfo(BlockType).@"enum".fields.len;
pub const deco_count = @typeInfo(DecoType).@"enum".fields.len;
pub const creature_count = @typeInfo(CreatureType).@"enum".fields.len;

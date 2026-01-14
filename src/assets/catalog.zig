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
    chicken,
    dog,
    horse,
    pig,
    raccoon,
    sheep,
    wolf,
};

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
        .chicken => "assets/chicken.glb",
        .dog => "assets/dog.glb",
        .horse => "assets/horse.glb",
        .pig => "assets/pig.glb",
        .raccoon => "assets/raccoon.glb",
        .sheep => "assets/sheep.glb",
        .wolf => "assets/wolf.glb",
    };
}

/// Returns the collision height of a decoration for terrain height calculations.
/// Trees are tall (6.0), flowers are short (0.5). Used to extend the effective
/// terrain surface upward so the drone can't fly through decoration geometry.
pub fn decoHeight(t: DecoType) f32 {
    return switch (t) {
        .none => 0.0,
        .tree => 6.0,
        .bamboo => 5.0,
        .flowers => 0.5,
        .plant => 1.5,
        .bush => 2.0,
        .crystal_small => 1.0,
        .crystal_big => 4.0,
    };
}

pub const block_count = @typeInfo(BlockType).@"enum".fields.len;
pub const deco_count = @typeInfo(DecoType).@"enum".fields.len;
pub const creature_count = @typeInfo(CreatureType).@"enum".fields.len;

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
    grass_tall,
    grass_small,
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

pub fn blockPath(t: BlockType) ?[:0]const u8 {
    return switch (t) {
        .air => null,
        .grass => "assets/Grass Block.glb",
        .dirt => "assets/Dirt Block.glb",
        .coal => "assets/Coal Block.glb",
        .snow => "assets/Snow Block.glb",
        .diamond => "assets/Diamond Block.glb",
        .crystal => "assets/Crystal Block.glb",
        .brick => "assets/Brick Block.glb",
        .wood_planks => "assets/Wood Planks Block.glb",
        .grey_bricks => "assets/Grey Bricks.glb",
    };
}

pub fn decoPath(t: DecoType) ?[:0]const u8 {
    return switch (t) {
        .none => null,
        .tree => "assets/Tree.glb",
        .bamboo => "assets/Bamboo.glb",
        .flowers => "assets/Flowers.glb",
        .grass_tall => "assets/Grass.glb",
        .grass_small => "assets/Grass Small.glb",
        .plant => "assets/Plant.glb",
        .bush => "assets/Bush.glb",
        .crystal_small => "assets/Crystal.glb",
        .crystal_big => "assets/Big Crystal.glb",
    };
}

pub fn creaturePath(t: CreatureType) ?[:0]const u8 {
    return switch (t) {
        .none => null,
        .cat => "assets/Cat.glb",
        .chicken => "assets/Chicken.glb",
        .dog => "assets/Dog.glb",
        .horse => "assets/Horse.glb",
        .pig => "assets/Pig.glb",
        .raccoon => "assets/Raccoon.glb",
        .sheep => "assets/Sheep.glb",
        .wolf => "assets/Wolf.glb",
    };
}

pub const block_count = @typeInfo(BlockType).@"enum".fields.len;
pub const deco_count = @typeInfo(DecoType).@"enum".fields.len;
pub const creature_count = @typeInfo(CreatureType).@"enum".fields.len;

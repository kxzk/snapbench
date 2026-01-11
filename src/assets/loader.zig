const rl = @import("../rl.zig");
const catalog = @import("catalog.zig");

pub const ModelCache = struct {
    blocks: [catalog.block_count]?rl.Model = .{null} ** catalog.block_count,
    decos: [catalog.deco_count]?rl.Model = .{null} ** catalog.deco_count,
    creatures: [catalog.creature_count]?rl.Model = .{null} ** catalog.creature_count,

    pub fn loadAll(self: *ModelCache) void {
        inline for (0..catalog.block_count) |i| {
            const t: catalog.BlockType = @enumFromInt(i);
            if (catalog.blockPath(t)) |path| {
                self.blocks[i] = rl.LoadModel(path);
            }
        }
        inline for (0..catalog.deco_count) |i| {
            const t: catalog.DecoType = @enumFromInt(i);
            if (catalog.decoPath(t)) |path| {
                self.decos[i] = rl.LoadModel(path);
            }
        }
        inline for (0..catalog.creature_count) |i| {
            const t: catalog.CreatureType = @enumFromInt(i);
            if (catalog.creaturePath(t)) |path| {
                self.creatures[i] = rl.LoadModel(path);
            }
        }
    }

    pub fn unloadAll(self: *ModelCache) void {
        inline for (.{ &self.blocks, &self.decos, &self.creatures }) |arr| {
            for (arr) |*slot| if (slot.*) |model| {
                rl.UnloadModel(model);
                slot.* = null;
            };
        }
    }

    pub fn getBlock(self: *const ModelCache, t: catalog.BlockType) ?rl.Model {
        return self.blocks[@intFromEnum(t)];
    }

    pub fn getDeco(self: *const ModelCache, t: catalog.DecoType) ?rl.Model {
        return self.decos[@intFromEnum(t)];
    }

    pub fn getCreature(self: *const ModelCache, t: catalog.CreatureType) ?rl.Model {
        return self.creatures[@intFromEnum(t)];
    }
};

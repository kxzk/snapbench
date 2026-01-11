const rl = @import("../rl.zig");
const catalog = @import("catalog.zig");

var instancing_shader: ?rl.Shader = null;

fn loadInstancingShader() rl.Shader {
    if (instancing_shader) |s| return s;

    var shader = rl.LoadShader("assets/shaders/instancing.vs", "assets/shaders/instancing.fs");
    shader.locs[rl.SHADER_LOC_MATRIX_MVP] = rl.GetShaderLocation(shader, "mvp");
    shader.locs[rl.SHADER_LOC_MATRIX_MODEL] = rl.GetShaderLocationAttrib(shader, "instanceTransform");
    shader.locs[rl.SHADER_LOC_COLOR_DIFFUSE] = rl.GetShaderLocation(shader, "colDiffuse");
    shader.locs[rl.SHADER_LOC_MAP_DIFFUSE] = rl.GetShaderLocation(shader, "texture0");
    instancing_shader = shader;
    return shader;
}

fn applyInstancingShader(model: *rl.Model) void {
    const shader = loadInstancingShader();
    for (model.materials[0..@intCast(model.materialCount)]) |*mat| {
        mat.shader = shader;
    }
}

pub const ModelCache = struct {
    blocks: [catalog.block_count]?rl.Model = .{null} ** catalog.block_count,
    decos: [catalog.deco_count]?rl.Model = .{null} ** catalog.deco_count,
    creatures: [catalog.creature_count]?rl.Model = .{null} ** catalog.creature_count,

    pub fn loadAll(self: *ModelCache) void {
        inline for (0..catalog.block_count) |i| {
            const t: catalog.BlockType = @enumFromInt(i);
            if (catalog.blockPath(t)) |path| {
                self.blocks[i] = rl.LoadModel(path);
                applyInstancingShader(&self.blocks[i].?);
            }
        }
        inline for (0..catalog.deco_count) |i| {
            const t: catalog.DecoType = @enumFromInt(i);
            if (catalog.decoPath(t)) |path| {
                self.decos[i] = rl.LoadModel(path);
                applyInstancingShader(&self.decos[i].?);
            }
        }
        inline for (0..catalog.creature_count) |i| {
            const t: catalog.CreatureType = @enumFromInt(i);
            if (catalog.creaturePath(t)) |path| {
                self.creatures[i] = rl.LoadModel(path);
                applyInstancingShader(&self.creatures[i].?);
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
        if (instancing_shader) |s| {
            rl.UnloadShader(s);
            instancing_shader = null;
        }
    }
};

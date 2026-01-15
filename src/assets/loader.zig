const rl = @import("../rl.zig");
const catalog = @import("catalog.zig");

var shader: ?rl.Shader = null;
var time_loc: c_int = -1;

fn loadShader() rl.Shader {
    if (shader) |s| return s;
    var s = rl.LoadShader("assets/shaders/instancing.vs", "assets/shaders/instancing.fs");
    s.locs[rl.SHADER_LOC_MATRIX_MVP] = rl.GetShaderLocation(s, "mvp");
    s.locs[rl.SHADER_LOC_MATRIX_MODEL] = rl.GetShaderLocationAttrib(s, "instanceTransform");
    s.locs[rl.SHADER_LOC_COLOR_DIFFUSE] = rl.GetShaderLocation(s, "colDiffuse");
    s.locs[rl.SHADER_LOC_MAP_DIFFUSE] = rl.GetShaderLocation(s, "texture0");
    time_loc = rl.GetShaderLocation(s, "time");
    shader = s;
    return s;
}

pub fn setShaderTime(time: f32) void {
    if (shader) |s| {
        rl.SetShaderValue(s, time_loc, &time, rl.SHADER_UNIFORM_FLOAT);
    }
}

fn applyShader(model: *rl.Model, s: rl.Shader) void {
    for (model.materials[0..@intCast(model.materialCount)]) |*mat| {
        mat.shader = s;
    }
}

pub const ModelCache = struct {
    blocks: [catalog.block_count]?rl.Model = .{null} ** catalog.block_count,
    decos: [catalog.deco_count]?rl.Model = .{null} ** catalog.deco_count,
    creatures: [catalog.creature_count]?rl.Model = .{null} ** catalog.creature_count,

    pub fn loadAll(self: *ModelCache) void {
        const s = loadShader();

        inline for (0..catalog.block_count) |i| {
            if (catalog.blockPath(@enumFromInt(i))) |path| {
                self.blocks[i] = rl.LoadModel(path);
                applyShader(&self.blocks[i].?, s);
            }
        }
        inline for (0..catalog.deco_count) |i| {
            if (catalog.decoPath(@enumFromInt(i))) |path| {
                self.decos[i] = rl.LoadModel(path);
                applyShader(&self.decos[i].?, s);
            }
        }
        inline for (0..catalog.creature_count) |i| {
            if (catalog.creaturePath(@enumFromInt(i))) |path| {
                self.creatures[i] = rl.LoadModel(path);
                applyShader(&self.creatures[i].?, s);
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
        if (shader) |s| {
            rl.UnloadShader(s);
            shader = null;
        }
    }
};

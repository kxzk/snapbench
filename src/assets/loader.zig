const rl = @import("../rl.zig");
const catalog = @import("catalog.zig");

var instancing_shader: ?rl.Shader = null;

/// Loads and caches the instancing shader, returning the cached version on subsequent calls.
/// Sets up shader uniform locations for MVP matrix, per-instance transforms, diffuse color,
/// and texture sampler. The shader enables hardware instancing for batch rendering.
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

/// Replaces all material shaders on a model with the instancing shader.
/// Must be called after loading each model to enable GPU instanced rendering.
fn applyInstancingShader(model: *rl.Model) void {
    const shader = loadInstancingShader();
    for (model.materials[0..@intCast(model.materialCount)]) |*mat| {
        mat.shader = shader;
    }
}

/// Caches loaded models by type for efficient lookup during rendering.
/// Indexed by enum values to avoid hash lookups. Optional slots handle types
/// without models (air blocks, no decoration/creature).
pub const ModelCache = struct {
    blocks: [catalog.block_count]?rl.Model = .{null} ** catalog.block_count,
    decos: [catalog.deco_count]?rl.Model = .{null} ** catalog.deco_count,
    creatures: [catalog.creature_count]?rl.Model = .{null} ** catalog.creature_count,

    /// Loads all models from disk and applies the instancing shader to each.
    /// Uses comptime inline loops to unroll loading; skips types with null paths.
    /// Call once at startup; models stay loaded for the application lifetime.
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

    /// Unloads all cached models and the shared instancing shader.
    /// Must be called before window close to properly release GPU resources.
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

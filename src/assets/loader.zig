const std = @import("std");
const rl = @import("../rl.zig").c;

pub fn loadModel(path: [:0]const u8) !rl.Model {
    if (!rl.FileExists(path)) {
        std.log.err("Missing model: {s}", .{path});
        return error.MissingModel;
    }
    const model = rl.LoadModel(path);
    // IsModelValid also requires skinning VBOs, even in raylib's default CPU
    // skinning build. These models are static; validate the buffers we draw.
    if (model.meshCount <= 0 or model.materialCount <= 0 or model.meshes == null or
        model.materials == null or model.meshMaterial == null)
    {
        unloadModel(model);
        std.log.err("Invalid model: {s}", .{path});
        return error.InvalidModel;
    }
    errdefer unloadModel(model);
    for (model.meshes[0..@intCast(model.meshCount)]) |mesh| {
        if (mesh.vertexCount <= 0 or mesh.vboId == null or mesh.vboId[0] == 0 or
            mesh.vboId[1] == 0 or mesh.vboId[2] == 0) return error.InvalidMesh;
    }
    return model;
}

/// GLB textures belong to each loaded model, but may be shared by its materials.
/// raylib's UnloadModel frees meshes and map arrays, not the textures themselves.
pub fn unloadModel(model: rl.Model) void {
    const materials = model.materials[0..@intCast(model.materialCount)];
    for (materials) |material| {
        for (material.maps[0 .. rl.MATERIAL_MAP_BRDF + 1]) |map| {
            const texture = map.texture;
            if (texture.id == 0 or texture.id == rl.rlGetTextureIdDefault()) continue;
            rl.UnloadTexture(texture);
            for (materials) |other| {
                for (other.maps[0 .. rl.MATERIAL_MAP_BRDF + 1]) |*shared| {
                    if (shared.texture.id == texture.id) shared.texture.id = 0;
                }
            }
        }
    }
    rl.UnloadModel(model);
}

pub fn loadIdleAnimation(path: [:0]const u8) ![*c]rl.ModelAnimation {
    var count: c_int = 0;
    const animations = rl.LoadModelAnimations(path, &count);
    const idle = @import("catalog.zig").creature_idle_clip;
    if (animations == null or count <= idle) {
        if (animations != null) rl.UnloadModelAnimations(animations, count);
        return error.MissingIdleAnimation;
    }
    defer rl.UnloadModelAnimations(animations, count);
    // Move the retained clip to its own array so raylib can own both cleanups.
    const selected: [*c]rl.ModelAnimation = @ptrCast(@alignCast(rl.MemAlloc(@sizeOf(rl.ModelAnimation)) orelse return error.OutOfMemory));
    selected[0] = animations[idle];
    animations[idle] = std.mem.zeroes(rl.ModelAnimation);
    return selected;
}

pub const InstanceShader = struct {
    shader: rl.Shader,
    mvp_location: c_int,
    color_location: c_int,
    time_location: c_int,
    camera_location: c_int,
    light_location: c_int,
    shadow_location: c_int,
    depth_pass_location: c_int,

    pub fn init() !InstanceShader {
        const shader = rl.LoadShader("assets/shaders/instancing.vs", "assets/shaders/instancing.fs");
        errdefer rl.UnloadShader(shader);
        if (!rl.IsShaderValid(shader) or shader.id == rl.rlGetShaderIdDefault()) return error.InvalidShader;
        const result: InstanceShader = .{
            .shader = shader,
            .mvp_location = rl.GetShaderLocation(shader, "mvp"),
            .color_location = rl.GetShaderLocation(shader, "colDiffuse"),
            .time_location = rl.GetShaderLocation(shader, "time"),
            .camera_location = rl.GetShaderLocation(shader, "cameraPosition"),
            .light_location = rl.GetShaderLocation(shader, "lightVP"),
            .shadow_location = rl.GetShaderLocation(shader, "shadowMap"),
            .depth_pass_location = rl.GetShaderLocation(shader, "depthPass"),
        };
        if (result.mvp_location < 0 or result.color_location < 0 or result.time_location < 0 or
            result.camera_location < 0 or result.light_location < 0 or result.shadow_location < 0 or result.depth_pass_location < 0 or
            rl.GetShaderLocationAttrib(shader, "instancePositionScale") != 8 or
            rl.GetShaderLocationAttrib(shader, "instanceVariation") != 9) return error.InvalidShader;
        return result;
    }

    pub fn deinit(self: *InstanceShader) void {
        rl.UnloadShader(self.shader);
    }
};

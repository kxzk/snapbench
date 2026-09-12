const rl = @import("../rl.zig").c;

pub const Environment = struct {
    sky: rl.Shader,
    water: rl.Shader,
    resolution: c_int,
    forward: c_int,
    right: c_int,
    up: c_int,
    water_camera: c_int,
    water_time: c_int,

    pub fn init() !Environment {
        const sky = rl.LoadShader(null, "assets/shaders/sky.fs");
        errdefer rl.UnloadShader(sky);
        const water = rl.LoadShader("assets/shaders/water.vs", "assets/shaders/water.fs");
        errdefer rl.UnloadShader(water);
        if (!rl.IsShaderValid(sky) or !rl.IsShaderValid(water) or sky.id == rl.rlGetShaderIdDefault() or water.id == rl.rlGetShaderIdDefault()) return error.InvalidEnvironmentShader;
        return .{ .sky = sky, .water = water, .resolution = rl.GetShaderLocation(sky, "resolution"), .forward = rl.GetShaderLocation(sky, "forward"), .right = rl.GetShaderLocation(sky, "right"), .up = rl.GetShaderLocation(sky, "up"), .water_camera = rl.GetShaderLocation(water, "cameraPosition"), .water_time = rl.GetShaderLocation(water, "time") };
    }

    pub fn deinit(self: Environment) void {
        rl.UnloadShader(self.sky);
        rl.UnloadShader(self.water);
    }

    pub fn drawSky(self: Environment, camera: rl.Camera3D, width: c_int, height: c_int) void {
        const resolution: rl.Vector2 = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
        const forward = rl.Vector3Normalize(rl.Vector3Subtract(camera.target, camera.position));
        const right = rl.Vector3Normalize(rl.Vector3CrossProduct(forward, camera.up));
        const up = rl.Vector3CrossProduct(right, forward);
        rl.SetShaderValue(self.sky, self.resolution, &resolution, rl.SHADER_UNIFORM_VEC2);
        rl.SetShaderValue(self.sky, self.forward, &forward, rl.SHADER_UNIFORM_VEC3);
        rl.SetShaderValue(self.sky, self.right, &right, rl.SHADER_UNIFORM_VEC3);
        rl.SetShaderValue(self.sky, self.up, &up, rl.SHADER_UNIFORM_VEC3);
        rl.BeginShaderMode(self.sky);
        rl.DrawRectangle(0, 0, width, height, rl.WHITE);
        rl.EndShaderMode();
    }

    pub fn drawWater(self: Environment, camera: rl.Camera3D, time: f32) void {
        rl.SetShaderValue(self.water, self.water_camera, &camera.position, rl.SHADER_UNIFORM_VEC3);
        rl.SetShaderValue(self.water, self.water_time, &time, rl.SHADER_UNIFORM_FLOAT);
        rl.BeginShaderMode(self.water);
        rl.DrawPlane(.{ .x = 0, .y = 0.8, .z = 0 }, .{ .x = 800, .y = 800 }, rl.WHITE);
        rl.EndShaderMode();
    }
};

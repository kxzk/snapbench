const std = @import("std");
const rl = @import("rl.zig");
const world_mod = @import("terrain/world.zig");
const terrain_renderer = @import("render/terrain_renderer.zig");
const loader = @import("assets/loader.zig");
const collision = @import("collision.zig");

const deg_to_rad = std.math.pi / 180.0;
const min_altitude: f32 = 1.0;
const world_half = world_mod.WORLD_HALF;

pub fn main() void {
    rl.InitWindow(1280, 720, "SnapBench");
    defer rl.CloseWindow();

    var camera = rl.Camera3D{
        .position = .{ .x = 0, .y = 50, .z = -100 },
        .target = .{ .x = 0, .y = 50, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 60,
        .projection = rl.CAMERA_PERSPECTIVE,
    };

    var model = rl.LoadModel("assets/drone.glb");
    defer rl.UnloadModel(model);

    var model_cache = loader.ModelCache{};
    model_cache.loadAll();
    defer model_cache.unloadAll();

    const terrain = world_mod.World.generate(@intCast(@as(u64, @bitCast(std.time.timestamp()))));
    const render_batch = terrain_renderer.RenderBatch.getStatic();
    terrain_renderer.collectBatches(&terrain, render_batch);

    var pos = rl.Vector3{ .x = 0, .y = 20, .z = 0 };
    var yaw: f32 = 0;
    var target_pos = pos;

    const move_speed: f32 = 30.0;
    const vertical_speed: f32 = 20.0;
    const yaw_speed: f32 = 90.0;
    const smoothing: f32 = 8.0;

    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        const dt = rl.GetFrameTime();
        const yaw_rad = yaw * deg_to_rad;
        const forward = rl.Vector3{ .x = @sin(yaw_rad), .y = 0, .z = @cos(yaw_rad) };
        const right = rl.Vector3{ .x = @cos(yaw_rad), .y = 0, .z = -@sin(yaw_rad) };

        if (rl.IsKeyDown(rl.KEY_W) or rl.IsKeyDown(rl.KEY_UP)) target_pos = rl.Vector3Add(target_pos, rl.Vector3Scale(forward, move_speed * dt));
        if (rl.IsKeyDown(rl.KEY_S) or rl.IsKeyDown(rl.KEY_DOWN)) target_pos = rl.Vector3Add(target_pos, rl.Vector3Scale(forward, -move_speed * dt));
        if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) target_pos = rl.Vector3Add(target_pos, rl.Vector3Scale(right, move_speed * dt));
        if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) target_pos = rl.Vector3Add(target_pos, rl.Vector3Scale(right, -move_speed * dt));
        if (rl.IsKeyDown(rl.KEY_SPACE)) target_pos.y += vertical_speed * dt;
        if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) target_pos.y -= vertical_speed * dt;
        if (rl.IsKeyDown(rl.KEY_Q)) yaw += yaw_speed * dt;
        if (rl.IsKeyDown(rl.KEY_E)) yaw -= yaw_speed * dt;

        const target_floor = collision.getTerrainHeight(&terrain, target_pos.x, target_pos.z);
        if (target_floor > pos.y - collision.DRONE_RADIUS) {
            target_pos.x = pos.x;
            target_pos.z = pos.z;
        }

        if (collision.checkCreatureCollision(&terrain, target_pos.x, target_pos.y, target_pos.z)) {
            target_pos = pos;
        }

        const floor_at_pos = collision.getBaseTerrainHeight(&terrain, target_pos.x, target_pos.z);
        target_pos.y = @max(target_pos.y, floor_at_pos + collision.DRONE_RADIUS);

        target_pos = clampToPlayArea(target_pos);
        pos = rl.Vector3Lerp(pos, target_pos, smoothing * dt);

        const model_scale: f32 = 5.0;
        const scale_mat = rl.MatrixScale(model_scale, model_scale, model_scale);
        const yaw_mat = rl.MatrixRotateY(yaw_rad + std.math.pi);
        const translate_mat = rl.MatrixTranslate(pos.x, pos.y, pos.z);
        model.transform = rl.MatrixMultiply(rl.MatrixMultiply(scale_mat, yaw_mat), translate_mat);

        const cam_offset = rl.Vector3{ .x = -forward.x * 25, .y = 12, .z = -forward.z * 25 };
        const target_cam_pos = rl.Vector3Add(pos, cam_offset);
        camera.position = rl.Vector3Lerp(camera.position, target_cam_pos, 5.0 * dt);
        camera.target = rl.Vector3Lerp(camera.target, pos, 10.0 * dt);

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.BLACK);
        drawEnvironmentGradient();

        {
            rl.BeginMode3D(camera);
            defer rl.EndMode3D();

            terrain_renderer.render(&model_cache, render_batch);

            rl.DrawModel(model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        }

        drawHUD(pos, yaw);
    }
}

fn drawHUD(pos: rl.Vector3, yaw: f32) void {
    const hud_bg = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 120 };
    const text_color = rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };

    rl.DrawRectangle(10, 10, 180, 110, hud_bg);
    rl.DrawText("DRONE", 20, 15, 14, text_color);
    rl.DrawText(rl.TextFormat("X: %.1f", pos.x), 20, 35, 16, text_color);
    rl.DrawText(rl.TextFormat("Y: %.1f", pos.y), 20, 55, 16, text_color);
    rl.DrawText(rl.TextFormat("Z: %.1f", pos.z), 20, 75, 16, text_color);
    rl.DrawFPS(20, 97);

    rl.DrawRectangle(10, 680, 260, 30, hud_bg);
    rl.DrawText("WASD:Move Q/E:Yaw Space/Shift:Up/Down", 15, 687, 10, text_color);

    const cx: i32 = 1280 - 60;
    const cy: i32 = 60;
    const yaw_rad = yaw * deg_to_rad;
    const arrow_len: f32 = 30;
    const ax: i32 = cx + @as(i32, @intFromFloat(@sin(yaw_rad) * arrow_len));
    const ay: i32 = cy - @as(i32, @intFromFloat(@cos(yaw_rad) * arrow_len));

    rl.DrawCircleLines(cx, cy, 40, text_color);
    rl.DrawLine(cx, cy, ax, ay, text_color);
    rl.DrawCircle(ax, ay, 4, text_color);
}

fn drawEnvironmentGradient() void {
    const w = rl.GetScreenWidth();
    const h = rl.GetScreenHeight();
    const half_h = @divTrunc(h, 2);
    const quarter_h = @divTrunc(h, 4);

    const sky_top = rl.Color{ .r = 0x87, .g = 0xCE, .b = 0xEB, .a = 255 };
    const sky_mid = rl.Color{ .r = 0xE8, .g = 0xD4, .b = 0xA8, .a = 255 };
    const horizon = rl.Color{ .r = 0xD4, .g = 0xA5, .b = 0x74, .a = 255 };
    const ground_mid = rl.Color{ .r = 0xC4, .g = 0x95, .b = 0x6A, .a = 255 };
    const ground_bottom = rl.Color{ .r = 0xA6, .g = 0x7B, .b = 0x5B, .a = 255 };

    rl.DrawRectangleGradientV(0, 0, w, quarter_h, sky_top, sky_mid);
    rl.DrawRectangleGradientV(0, quarter_h, w, quarter_h, sky_mid, horizon);
    rl.DrawRectangleGradientV(0, half_h, w, quarter_h, horizon, ground_mid);
    rl.DrawRectangleGradientV(0, half_h + quarter_h, w, quarter_h, ground_mid, ground_bottom);
}

fn clampToPlayArea(p: rl.Vector3) rl.Vector3 {
    return .{
        .x = std.math.clamp(p.x, -world_half, world_half),
        .y = @max(p.y, min_altitude),
        .z = std.math.clamp(p.z, -world_half, world_half),
    };
}

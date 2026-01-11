const std = @import("std");
const rl = @import("rl.zig");
const world_mod = @import("terrain/world.zig");
const terrain_renderer = @import("render/terrain_renderer.zig");
const loader = @import("assets/loader.zig");
const collision = @import("collision.zig");

const deg_to_rad = std.math.pi / 180.0;
const min_altitude: f32 = 1.0;
const world_half = world_mod.WORLD_HALF;

const Directions = struct { forward: rl.Vector3, right: rl.Vector3 };

fn yawToDirections(yaw_rad: f32) Directions {
    return .{
        .forward = .{ .x = @sin(yaw_rad), .y = 0, .z = @cos(yaw_rad) },
        .right = .{ .x = @cos(yaw_rad), .y = 0, .z = -@sin(yaw_rad) },
    };
}

fn handleInput(target_pos: *rl.Vector3, yaw: *f32, dirs: Directions, dt: f32) void {
    const move_speed: f32 = 30.0;
    const vertical_speed: f32 = 20.0;
    const yaw_speed: f32 = 90.0;

    if (rl.IsKeyDown(rl.KEY_W) or rl.IsKeyDown(rl.KEY_UP)) target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.forward, move_speed * dt));
    if (rl.IsKeyDown(rl.KEY_S) or rl.IsKeyDown(rl.KEY_DOWN)) target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.forward, -move_speed * dt));
    if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.right, -move_speed * dt));
    if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.right, move_speed * dt));
    if (rl.IsKeyDown(rl.KEY_SPACE)) target_pos.y += vertical_speed * dt;
    if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) target_pos.y -= vertical_speed * dt;
    if (rl.IsKeyDown(rl.KEY_Q)) yaw.* -= yaw_speed * dt;
    if (rl.IsKeyDown(rl.KEY_E)) yaw.* += yaw_speed * dt;
}

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
    var render_batch = terrain_renderer.RenderBatch{};
    terrain_renderer.collectBatches(&terrain, &render_batch);

    var pos = rl.Vector3{ .x = 0, .y = 20, .z = 0 };
    var yaw: f32 = 0;
    var target_pos = pos;

    const smoothing: f32 = 8.0;

    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        const dt = rl.GetFrameTime();
        const dirs = yawToDirections(yaw * deg_to_rad);

        // Drone visually faces { sin(yaw), 0, -cos(yaw) } due to +π transform
        // So movement forward should match that (negate Z component)
        const drone_dirs = Directions{
            .forward = .{ .x = dirs.forward.x, .y = 0, .z = -dirs.forward.z },
            .right = dirs.right,
        };

        handleInput(&target_pos, &yaw, drone_dirs, dt);
        const updated_yaw_rad = yaw * deg_to_rad;

        const resolved = collision.resolveMove(
            &terrain,
            .{ .x = pos.x, .y = pos.y, .z = pos.z },
            .{ .x = target_pos.x, .y = target_pos.y, .z = target_pos.z },
        );
        target_pos = .{ .x = resolved.x, .y = resolved.y, .z = resolved.z };

        target_pos = clampToPlayArea(target_pos);
        pos = rl.Vector3Lerp(pos, target_pos, smoothing * dt);

        model.transform = makeTRS(pos, updated_yaw_rad, 5.0);

        // Camera behind drone: drone faces {sin(yaw), 0, -cos(yaw)}, so behind is {-sin(yaw), 0, cos(yaw)}
        const cam_dirs = yawToDirections(yaw * deg_to_rad);
        const cam_offset = rl.Vector3{ .x = -cam_dirs.forward.x * 25, .y = 12, .z = cam_dirs.forward.z * 25 };
        camera.position = rl.Vector3Add(pos, cam_offset);
        camera.target = pos;

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.BLACK);
        drawEnvironmentGradient();

        {
            rl.BeginMode3D(camera);
            defer rl.EndMode3D();

            terrain_renderer.render(&model_cache, &render_batch);

            rl.DrawModel(model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        }

        drawHUD(pos, yaw);
    }
}

const hud_bg = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 120 };
const hud_text = rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };

fn drawHUD(pos: rl.Vector3, yaw: f32) void {
    drawDroneInfo(pos);
    drawControls();
    drawCompass(yaw);
}

fn drawDroneInfo(pos: rl.Vector3) void {
    rl.DrawRectangle(10, 10, 180, 110, hud_bg);
    rl.DrawText("DRONE", 20, 15, 14, hud_text);
    rl.DrawText(rl.TextFormat("X: %.1f", pos.x), 20, 35, 16, hud_text);
    rl.DrawText(rl.TextFormat("Y: %.1f", pos.y), 20, 55, 16, hud_text);
    rl.DrawText(rl.TextFormat("Z: %.1f", pos.z), 20, 75, 16, hud_text);
    rl.DrawFPS(20, 97);
}

fn drawControls() void {
    rl.DrawRectangle(10, 680, 260, 30, hud_bg);
    rl.DrawText("WASD:Move Q/E:Yaw Space/Shift:Up/Down", 15, 687, 10, hud_text);
}

fn drawCompass(yaw: f32) void {
    const cx: i32 = rl.GetScreenWidth() - 60;
    const cy: i32 = 60;
    const yaw_rad = yaw * deg_to_rad;
    const arrow_len: f32 = 30;
    const ax: i32 = cx + @as(i32, @intFromFloat(@sin(yaw_rad) * arrow_len));
    const ay: i32 = cy - @as(i32, @intFromFloat(@cos(yaw_rad) * arrow_len));

    rl.DrawCircleLines(cx, cy, 40, hud_text);
    rl.DrawLine(cx, cy, ax, ay, hud_text);
    rl.DrawCircle(ax, ay, 4, hud_text);
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

fn makeTRS(pos: rl.Vector3, yaw: f32, scale: f32) rl.Matrix {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{
        .m0 = scale * c,  .m1 = 0, .m2 = scale * s,  .m3 = 0,
        .m4 = 0,          .m5 = scale, .m6 = 0,       .m7 = 0,
        .m8 = scale * -s, .m9 = 0, .m10 = scale * c, .m11 = 0,
        .m12 = pos.x,     .m13 = pos.y, .m14 = pos.z, .m15 = 1,
    };
}

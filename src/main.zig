const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
});
const std = @import("std");

const deg_to_rad = std.math.pi / 180.0;
const min_altitude: f32 = 1.0;

pub fn main() void {
    rl.InitWindow(1280, 720, "Drone Sim");
    defer rl.CloseWindow();

    rl.DisableCursor();

    var camera = rl.Camera3D{
        .position = .{ .x = 0, .y = 50, .z = -100 },
        .target = .{ .x = 0, .y = 50, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 60,
        .projection = rl.CAMERA_PERSPECTIVE,
    };

    var model = rl.LoadModel("assets/Drone.glb");
    defer rl.UnloadModel(model);

    var pos = rl.Vector3{ .x = 0, .y = 10, .z = 0 };
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
        if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) target_pos = rl.Vector3Add(target_pos, rl.Vector3Scale(right, -move_speed * dt));
        if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) target_pos = rl.Vector3Add(target_pos, rl.Vector3Scale(right, move_speed * dt));
        if (rl.IsKeyDown(rl.KEY_SPACE)) target_pos.y += vertical_speed * dt;
        if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) target_pos.y -= vertical_speed * dt;
        if (rl.IsKeyDown(rl.KEY_Q)) yaw += yaw_speed * dt;
        if (rl.IsKeyDown(rl.KEY_E)) yaw -= yaw_speed * dt;

        target_pos.y = @max(target_pos.y, min_altitude);
        pos = rl.Vector3Lerp(pos, target_pos, smoothing * dt);
        pos.y = @max(pos.y, min_altitude);

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

        rl.ClearBackground(.{ .r = 122, .g = 127, .b = 133, .a = 255 });

        {
            rl.BeginMode3D(camera);
            defer rl.EndMode3D();

            drawGrid(100, 5.0, .{ .r = 105, .g = 110, .b = 116, .a = 255 });
            rl.DrawModel(model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, rl.WHITE);
        }

        drawHUD(pos, yaw);
    }
}

fn drawHUD(pos: rl.Vector3, yaw: f32) void {
    const hud_bg = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 150 };

    rl.DrawRectangle(10, 10, 180, 90, hud_bg);
    rl.DrawText("DRONE", 20, 15, 14, rl.RAYWHITE);
    rl.DrawText(rl.TextFormat("X: %.1f", pos.x), 20, 35, 16, rl.GREEN);
    rl.DrawText(rl.TextFormat("Y: %.1f", pos.y), 20, 55, 16, rl.GREEN);
    rl.DrawText(rl.TextFormat("Z: %.1f", pos.z), 20, 75, 16, rl.GREEN);

    rl.DrawRectangle(10, 680, 260, 30, hud_bg);
    rl.DrawText("WASD:Move Q/E:Yaw Space/Shift:Up/Down", 15, 687, 10, rl.RAYWHITE);

    const cx: i32 = 1280 - 60;
    const cy: i32 = 60;
    const yaw_rad = yaw * deg_to_rad;
    const arrow_len: f32 = 30;
    const ax: i32 = cx + @as(i32, @intFromFloat(@sin(yaw_rad) * arrow_len));
    const ay: i32 = cy - @as(i32, @intFromFloat(@cos(yaw_rad) * arrow_len));

    rl.DrawCircleLines(cx, cy, 40, rl.RAYWHITE);
    rl.DrawLine(cx, cy, ax, ay, rl.ORANGE);
    rl.DrawCircle(ax, ay, 4, rl.ORANGE);
}

fn drawGrid(slices: i32, spacing: f32, color: rl.Color) void {
    const half: f32 = @as(f32, @floatFromInt(slices)) * spacing / 2.0;

    for (0..@intCast(slices + 1)) |i| {
        const offset: f32 = @as(f32, @floatFromInt(i)) * spacing - half;

        rl.DrawLine3D(
            .{ .x = offset, .y = 0, .z = -half },
            .{ .x = offset, .y = 0, .z = half },
            color,
        );

        rl.DrawLine3D(
            .{ .x = -half, .y = 0, .z = offset },
            .{ .x = half, .y = 0, .z = offset },
            color,
        );
    }
}

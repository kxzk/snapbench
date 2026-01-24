const std = @import("std");
const rl = @import("rl.zig");
const math = @import("math.zig");
const world_mod = @import("terrain/world.zig");
const terrain_renderer = @import("render/terrain_renderer.zig");
const loader = @import("assets/loader.zig");
const collision = @import("collision.zig");
const udp = @import("udp.zig");
const game_state = @import("game_state.zig");

const deg_to_rad = std.math.pi / 180.0;
const min_altitude: f32 = 1.0;
const world_half = world_mod.WORLD_HALF;

// UDP commands are discrete actions, not continuous input - no dt scaling
const udp_horizontal: f32 = 1.5; // units per command
const udp_vertical: f32 = 1.0; // units per command
const udp_rotation: f32 = 22.5; // degrees per command (16 steps = full rotation)

const Command = enum { forward, backward, left, right, up, down, rotate_left, rotate_right, identify, screenshot, unknown };

fn parseCommand(data: []const u8) Command {
    const trimmed = std.mem.trimRight(u8, data, &.{ '\n', '\r', ' ' });
    return std.meta.stringToEnum(Command, trimmed) orelse .unknown;
}

const Directions = struct { forward: rl.Vector3, right: rl.Vector3 };

fn yawToDirections(yaw_rad: f32) Directions {
    return .{
        .forward = .{ .x = @sin(yaw_rad), .y = 0, .z = @cos(yaw_rad) },
        .right = .{ .x = @cos(yaw_rad), .y = 0, .z = -@sin(yaw_rad) },
    };
}

fn yawToDroneDirections(yaw_rad: f32) Directions {
    const dirs = yawToDirections(yaw_rad);
    // Drone visually faces { sin(yaw), 0, -cos(yaw) } due to +π transform
    return .{
        .forward = .{ .x = dirs.forward.x, .y = 0, .z = -dirs.forward.z },
        .right = dirs.right,
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
    if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT) and !rl.IsKeyDown(rl.KEY_LEFT_SUPER)) target_pos.y -= vertical_speed * dt;
    if (rl.IsKeyDown(rl.KEY_Q)) yaw.* -= yaw_speed * dt;
    if (rl.IsKeyDown(rl.KEY_E)) yaw.* += yaw_speed * dt;
}

const WorldSeed = struct {
    number: ?u64,
    hash: u64,
};

fn parseWorldSeed() WorldSeed {
    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |arg| {
        if (std.fmt.parseInt(u64, arg, 10)) |num| {
            return .{ .number = num, .hash = world_mod.hashSeed(num) };
        } else |_| {
            std.debug.print("Warning: Invalid seed '{s}', using random\n", .{arg});
        }
    }
    // nanoTimestamp: 1-second resolution would cause collisions in rapid re-runs
    const ns: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    return .{ .number = null, .hash = world_mod.hashSeed(ns) };
}

pub fn main() void {
    const world_seed = parseWorldSeed();

    rl.InitWindow(1280, 720, "SnapBench");
    defer rl.CloseWindow();

    // Tighter clip planes for better depth buffer precision (reduces Z-fighting artifacts)
    rl.rlSetClipPlanes(1.0, 500.0);

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

    var terrain = world_mod.World.generate(world_seed.hash);
    var render_batch = terrain_renderer.RenderBatch{};
    terrain_renderer.collectBatches(&terrain, &render_batch);

    // Warm-up frame: force GPU to allocate and sync instance buffers before main loop
    // Prevents black streak artifacts on first camera movement (Metal driver timing issue)
    rl.BeginDrawing();
    rl.ClearBackground(rl.BLACK);
    {
        rl.BeginMode3D(camera);
        defer rl.EndMode3D();
        terrain_renderer.render(&model_cache, &render_batch);
    }
    rl.EndDrawing();

    var state = game_state.GameState{};
    var server = udp.UdpServer.init() catch |err| {
        std.debug.print("UDP init failed: {}\n", .{err});
        return;
    };
    defer server.deinit();
    var cmd_buf: [256]u8 = undefined;
    var response_buf: [128]u8 = undefined;

    var pos = rl.Vector3{ .x = 0, .y = 20, .z = 0 };
    var yaw: f32 = 0;
    var target_pos = pos;

    const smoothing: f32 = 8.0;

    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        const dt = rl.GetFrameTime();
        var drone_dirs = yawToDroneDirections(yaw * deg_to_rad);

        if (!state.game_over) {
            handleInput(&target_pos, &yaw, drone_dirs, dt);
        }

        while (server.tryRecv(&cmd_buf)) |recv| {
            var yaw_changed = false;
            const response = handleUdpCommand(
                parseCommand(recv.data),
                &target_pos,
                pos,
                &yaw,
                &terrain,
                &state,
                drone_dirs,
                &response_buf,
                &yaw_changed,
            );
            server.send(response, recv.client);
            if (yaw_changed) {
                drone_dirs = yawToDroneDirections(yaw * deg_to_rad);
            }
        }

        if (terrain.creatures_dirty) {
            terrain_renderer.collectCreatureBatch(&terrain, &render_batch);
            terrain.creatures_dirty = false;
        }

        const updated_yaw_rad = yaw * deg_to_rad;
        const updated_dirs = yawToDirections(updated_yaw_rad);

        const dx = target_pos.x - pos.x;
        const dy = target_pos.y - pos.y;
        const dz = target_pos.z - pos.z;
        const move_dist_sq = dx * dx + dy * dy + dz * dz;
        if (move_dist_sq > 0.0001) {
            const resolved = collision.resolveMove(
                &terrain,
                .{ .x = pos.x, .y = pos.y, .z = pos.z },
                .{ .x = target_pos.x, .y = target_pos.y, .z = target_pos.z },
            );
            target_pos = .{ .x = resolved.x, .y = resolved.y, .z = resolved.z };
        }

        target_pos = clampToPlayArea(target_pos);
        pos = rl.Vector3Lerp(pos, target_pos, smoothing * dt);

        model.transform = math.matrixTRS(pos, updated_yaw_rad, 5.0);

        const cam_offset = rl.Vector3{ .x = -updated_dirs.forward.x * 25, .y = 12, .z = updated_dirs.forward.z * 25 };
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

        drawHUD(pos, yaw, state, world_seed.number);
        if (state.game_over) drawGameOver();
    }
}

fn formatResponse(buf: *[128]u8, prefix: []const u8, p: rl.Vector3, yaw: f32, min_dist: ?f32, remaining: ?u8) []const u8 {
    if (remaining) |r| {
        if (min_dist) |d| {
            return std.fmt.bufPrint(buf, "{s} x={d:.1} y={d:.1} z={d:.1} yaw={d:.1} remaining={d} min_dist={d:.2}", .{
                prefix, p.x, p.y, p.z, yaw, r, d,
            }) catch "ERR";
        }
        return std.fmt.bufPrint(buf, "{s} x={d:.1} y={d:.1} z={d:.1} yaw={d:.1} remaining={d} min_dist=none", .{
            prefix, p.x, p.y, p.z, yaw, r,
        }) catch "ERR";
    }
    if (min_dist) |d| {
        return std.fmt.bufPrint(buf, "{s} x={d:.1} y={d:.1} z={d:.1} yaw={d:.1} min_dist={d:.2}", .{
            prefix, p.x, p.y, p.z, yaw, d,
        }) catch "ERR";
    }
    return std.fmt.bufPrint(buf, "{s} x={d:.1} y={d:.1} z={d:.1} yaw={d:.1} min_dist=none", .{
        prefix, p.x, p.y, p.z, yaw,
    }) catch "ERR";
}

fn handleUdpCommand(
    cmd: Command,
    target_pos: *rl.Vector3,
    pos: rl.Vector3,
    yaw: *f32,
    terrain: *world_mod.World,
    state: *game_state.GameState,
    dirs: Directions,
    buf: *[128]u8,
    yaw_changed: *bool,
) []const u8 {
    if (cmd == .unknown) return "FAIL:unknown_command";
    yaw_changed.* = false;

    if (state.game_over) {
        return formatResponse(buf, "OK", pos, yaw.*, null, null);
    }

    switch (cmd) {
        .forward => target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.forward, udp_horizontal)),
        .backward => target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.forward, -udp_horizontal)),
        .left => target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.right, -udp_horizontal)),
        .right => target_pos.* = rl.Vector3Add(target_pos.*, rl.Vector3Scale(dirs.right, udp_horizontal)),
        .up => target_pos.y += udp_vertical,
        .down => target_pos.y -= udp_vertical,
        .rotate_left => {
            yaw.* -= udp_rotation;
            yaw_changed.* = true;
        },
        .rotate_right => {
            yaw.* += udp_rotation;
            yaw_changed.* = true;
        },
        .identify => {
            if (game_state.tryIdentify(terrain, state, pos.x, pos.y, pos.z)) {
                const new_min_dist = game_state.minDistanceToCreature(terrain, pos.x, pos.y, pos.z);
                return formatResponse(buf, "OK:identified", pos, yaw.*, new_min_dist, state.remaining());
            }
            const min_dist = game_state.minDistanceToCreature(terrain, pos.x, pos.y, pos.z);
            return formatResponse(buf, "FAIL:no_creature_in_range", pos, yaw.*, min_dist, null);
        },
        .screenshot => {
            rl.TakeScreenshot("screenshot.png");
            return "OK:screenshot";
        },
        .unknown => unreachable,
    }

    const min_dist = game_state.minDistanceToCreature(terrain, pos.x, pos.y, pos.z);
    return formatResponse(buf, "OK", target_pos.*, yaw.*, min_dist, null);
}

const hud_bg = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 120 };
const hud_text = rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };

fn drawHUD(pos: rl.Vector3, yaw: f32, state: game_state.GameState, world_number: ?u64) void {
    drawDroneInfo(pos, state, world_number);
    drawControls();
    drawCompass(yaw);
}

fn drawDroneInfo(pos: rl.Vector3, state: game_state.GameState, world_number: ?u64) void {
    rl.DrawRectangle(10, 10, 180, 150, hud_bg);
    rl.DrawText("DRONE", 20, 15, 14, hud_text);
    rl.DrawText(rl.TextFormat("X: %.1f", pos.x), 20, 35, 16, hud_text);
    rl.DrawText(rl.TextFormat("Y: %.1f", pos.y), 20, 55, 16, hud_text);
    rl.DrawText(rl.TextFormat("Z: %.1f", pos.z), 20, 75, 16, hud_text);
    rl.DrawText(rl.TextFormat("Creatures: %d/%d", state.creatures_found, game_state.TOTAL_CREATURES), 20, 95, 16, hud_text);
    if (world_number) |num| {
        rl.DrawText(rl.TextFormat("World: %d", num), 20, 115, 16, hud_text);
    } else {
        rl.DrawText("World: random", 20, 115, 16, hud_text);
    }
    rl.DrawFPS(20, 137);
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

fn drawGameOver() void {
    const w = rl.GetScreenWidth();
    const h = rl.GetScreenHeight();
    rl.DrawRectangle(0, 0, w, h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 180 });
    const text = "ALL CREATURES FOUND";
    const font_size: i32 = 40;
    const text_width = rl.MeasureText(text, font_size);
    rl.DrawText(text, @divTrunc(w - text_width, 2), @divTrunc(h, 2) - 20, font_size, rl.WHITE);
}

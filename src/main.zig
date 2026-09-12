const std = @import("std");
const rl = @import("rl.zig").c;
const TerrainRenderer = @import("render/terrain_renderer.zig").TerrainRenderer;
const DroneRenderer = @import("render/drone.zig").DroneRenderer;
const Environment = @import("render/environment.zig").Environment;
const AgentApi = @import("agent_api.zig").AgentApi;
const sim = @import("simulation.zig");
const cameras = @import("camera.zig");
const Hud = @import("hud.zig").Hud;
const Keyboard = @import("input.zig").Keyboard;
const Options = @import("options.zig").Options;
const FrameProfile = @import("frame_profile.zig").FrameProfile;
const Screenshot = @import("screenshot.zig").Screenshot;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = Options.parse(args[1..]) catch |err| {
        std.debug.print("Usage: snapbench [seed] [--scenario island|legacy] [--fps N] [--profile frames] [--tour] [--photo] [--debug] [--fast-agent]\n", .{});
        return err;
    };
    var random: [2]u64 = undefined;
    init.io.random(std.mem.asBytes(&random));
    var api = try AgentApi.init(init.io, init.gpa, random[1]);
    api.fast_actions = options.fast_agent;
    defer api.deinit();
    var profile = try FrameProfile.init(init.gpa, options.profile_frames);
    defer profile.deinit(init.gpa);
    defer profile.report();
    rl.SetConfigFlags(@intCast(rl.FLAG_MSAA_4X_HINT | if (options.fps == null) @as(c_int, rl.FLAG_VSYNC_HINT) else 0));
    rl.InitWindow(1280, 720, "SnapBench");
    defer rl.CloseWindow();
    if (!rl.IsWindowReady()) return error.WindowInitializationFailed;
    rl.rlSetClipPlanes(0.1, 500);
    rl.SetTargetFPS(options.fps orelse 0);
    if (rl.MakeDirectory(".snapbench/observations") != 0 and !rl.DirectoryExists(".snapbench/observations")) return error.ObservationDirectoryUnavailable;

    var simulation = sim.Simulation.init(options.seed orelse random[0], options.scenario);
    var renderer = try TerrainRenderer.init(init.gpa, &simulation.terrain);
    defer renderer.deinit();
    const drone_renderer = try DroneRenderer.init();
    defer drone_renderer.deinit();
    const environment = try Environment.init();
    defer environment.deinit();
    var hud = try Hud.init();
    defer hud.deinit();
    hud.debug = options.debug;
    var rig: cameras.Rig = .{ .mode = if (options.photo) .photo else .chase };
    var keyboard: Keyboard = .{};
    var screenshot = try Screenshot.init();
    defer screenshot.deinit();
    const observation = rl.LoadRenderTexture(cameras.sensor_width, cameras.sensor_height);
    defer rl.UnloadRenderTexture(observation);
    if (!rl.IsRenderTextureValid(observation)) return error.ObservationBufferUnavailable;

    while (!rl.WindowShouldClose()) {
        const frame_start = rl.GetTime();
        const dt = @min(rl.GetFrameTime(), 0.1);
        const completed = screenshot.poll() catch |err| blk: {
            std.log.warn("Screenshot readback failed: {t}", .{err});
            break :blk false;
        };
        if (completed) |succeeded| api.completeCapture(succeeded);
        var rebuild = try api.poll(&simulation, dt);
        if (options.profile_frames == 0) {
            keyboard.collect();
            if (keyboard.takePress(rl.KEY_TAB)) rig.mode = if (rig.mode == .chase) .photo else .chase;
            if (keyboard.takePress(rl.KEY_F3)) hud.debug = !hud.debug;
            if (keyboard.takePress(rl.KEY_R) and !screenshot.busy()) {
                api.cancel();
                simulation = sim.Simulation.init(simulation.seed, simulation.terrain.scenario);
                hud.notice_until = 0;
                rig.distance = 23;
                rebuild = true;
            }
            if (keyboard.takePress(rl.KEY_P) and !simulation.externally_clocked) hud.notify(simulation.identify());
        }
        if (rebuild) {
            const replacement = try TerrainRenderer.init(init.gpa, &simulation.terrain);
            renderer.deinit();
            renderer = replacement;
            rig.distance = 23;
        } else if (simulation.terrain.creatures_dirty) {
            try renderer.updateCreatures(&simulation.terrain);
            simulation.terrain.creatures_dirty = false;
        }
        const tick = simulation.tick;
        const input: sim.Input = if (options.tour) .{ .forward = 0.55, .turn = 0.25 } else if (options.profile_frames == 0) keyboard.input() else .{};
        simulation.advance(dt, input);
        if (simulation.tick != tick) keyboard.clear();
        const drone = simulation.visualDrone();
        const camera = rig.update(drone, &simulation.terrain, dt);
        const time = simulation.time();
        renderer.prepare(time, api.wantsCapture(), drone_renderer, drone);

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        environment.drawSky(camera, rl.GetScreenWidth(), rl.GetScreenHeight());
        rl.BeginMode3D(camera);
        if (simulation.terrain.scenario == .island) environment.drawWater(camera, time);
        renderer.render(camera, time, 1280.0 / 720.0);
        if (rig.mode == .chase) drone_renderer.draw(drone, time);
        rl.EndMode3D();
        hud.draw(&simulation, rig.mode, renderer.visible_chunks);

        if (api.wantsCapture()) {
            const sensor = cameras.sensor(simulation.drone);
            rl.BeginTextureMode(observation);
            rl.ClearBackground(rl.BLACK);
            environment.drawSky(sensor, cameras.sensor_width, cameras.sensor_height);
            rl.BeginMode3D(sensor);
            if (simulation.terrain.scenario == .island) environment.drawWater(sensor, time);
            renderer.render(sensor, time, 1280.0 / 720.0);
            rl.EndMode3D();
            rl.rlDrawRenderBatchActive();
            screenshot.start(std.mem.sliceTo(&api.image_path, 0), cameras.sensor_width, cameras.sensor_height) catch |err| {
                std.log.warn("Screenshot failed: {t}", .{err});
                api.completeCapture(false);
            };
            if (screenshot.busy()) api.captured(&simulation);
            rl.EndTextureMode();
        }
        const work_seconds = rl.GetTime() - frame_start;
        rl.EndDrawing();
        if (profile.record(rl.GetFrameTime(), work_seconds)) break;
    }
}

test {
    _ = @import("udp.zig");
    _ = @import("options.zig");
    _ = @import("collision.zig");
    _ = @import("game_state.zig");
    _ = @import("motion.zig");
    _ = @import("protocol.zig");
    _ = @import("simulation.zig");
    _ = @import("agent_api.zig");
    _ = @import("terrain/world.zig");
    _ = @import("terrain/island.zig");
    _ = @import("render/terrain_renderer.zig");
    _ = @import("render/visibility.zig");
}

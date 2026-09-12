const std = @import("std");
const world = @import("terrain/world.zig");
const motion = @import("motion.zig");
const game = @import("game_state.zig");

pub const tick_rate = 120;
pub const tick_seconds: f64 = 1.0 / @as(f64, tick_rate);

pub const Action = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
    rotate_left,
    rotate_right,
    look_up,
    look_down,
    wait,
    identify,
};

pub const Input = struct {
    forward: f32 = 0,
    right: f32 = 0,
    up: f32 = 0,
    turn: f32 = 0,
    look: f32 = 0,

    pub fn action(value: Action) Input {
        return switch (value) {
            .forward => .{ .forward = 1 },
            .backward => .{ .forward = -1 },
            .left => .{ .right = -1 },
            .right => .{ .right = 1 },
            .up => .{ .up = 1 },
            .down => .{ .up = -1 },
            .rotate_left => .{ .turn = -1 },
            .rotate_right => .{ .turn = 1 },
            .look_up => .{ .look = 1 },
            .look_down => .{ .look = -1 },
            .wait, .identify => .{},
        };
    }
};

pub const Simulation = struct {
    terrain: world.World,
    seed: u64,
    drone: motion.Drone = .{},
    previous: motion.Drone = .{},
    tick: u64 = 0,
    accumulator: f64 = 0,
    externally_clocked: bool = false,

    pub fn init(seed: u64, scenario: world.Scenario) Simulation {
        return .{ .terrain = world.World.create(world.hashSeed(seed), scenario), .seed = seed };
    }

    pub fn step(self: *Simulation, input: Input) void {
        self.previous = self.drone;
        const dt: f32 = @floatCast(tick_seconds);
        if (!self.gameOver()) {
            const length = @sqrt(input.forward * input.forward + input.right * input.right);
            const scale = 18 * dt / @max(length, 1);
            self.drone.rotate(input.turn * 90 * dt);
            self.drone.pitch = std.math.clamp(self.drone.pitch + input.look * 45 * dt, -75, 45);
            self.drone.move(input.forward * scale, input.right * scale, input.up * 12 * dt);
        }
        self.drone.update(&self.terrain, dt);
        self.tick += 1;
    }

    pub fn advance(self: *Simulation, seconds: f64, input: Input) void {
        if (self.externally_clocked) return;
        self.accumulator += std.math.clamp(seconds, 0, 0.1);
        // Bound catch-up after a breakpoint without changing the simulation step.
        while (self.accumulator + 1e-10 >= tick_seconds) {
            self.step(input);
            self.accumulator = @max(self.accumulator - tick_seconds, 0);
        }
    }

    pub fn visualDrone(self: *const Simulation) motion.Drone {
        if (self.externally_clocked) return self.drone;
        return motion.Drone.interpolate(self.previous, self.drone, @floatCast(self.accumulator / tick_seconds));
    }

    pub fn time(self: *const Simulation) f32 {
        return @floatCast((@as(f64, @floatFromInt(self.tick)) + if (self.externally_clocked) @as(f64, 0) else self.accumulator / tick_seconds) * tick_seconds);
    }

    pub fn identify(self: *Simulation) bool {
        return if (self.terrain.scenario == .legacy)
            game.tryIdentify(&self.terrain, self.drone.position.x, self.drone.position.y, self.drone.position.z)
        else
            game.tryPhotograph(&self.terrain, @import("camera.zig").sensor(self.drone));
    }

    pub fn creaturesFound(self: *const Simulation) usize {
        return game.total_creatures - self.terrain.creature_count;
    }

    pub fn gameOver(self: *const Simulation) bool {
        return self.terrain.creature_count == 0;
    }
};

test "fixed simulation reaches the same state at 30 60 and 144 render FPS" {
    var reference = Simulation.init(42, .island);
    for (0..240) |_| reference.step(.{ .forward = 1, .turn = 0.2 });
    for ([_]u32{ 30, 60, 144 }) |fps| {
        var simulation = Simulation.init(42, .island);
        for (0..fps * 2) |_| simulation.advance(1.0 / @as(f64, @floatFromInt(fps)), .{ .forward = 1, .turn = 0.2 });
        try std.testing.expectEqual(reference.tick, simulation.tick);
        try std.testing.expectEqualDeep(reference.drone, simulation.drone);
    }
}

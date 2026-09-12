const std = @import("std");
const game = @import("game_state.zig");
const Simulation = @import("simulation.zig").Simulation;

pub const Command = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
    rotate_left,
    rotate_right,
    identify,
    screenshot,
    state,
    unknown,

    pub fn parse(data: []const u8) Command {
        const trimmed = std.mem.trim(u8, data, "\n\r\t ");
        return std.meta.stringToEnum(Command, trimmed) orelse .unknown;
    }
};

pub fn apply(command: Command, simulation: *Simulation) []const u8 {
    if (command == .unknown) return "FAIL:unknown_command";
    if (command == .screenshot) return "OK:screenshot";
    if (command == .state or simulation.gameOver()) return "OK";
    const drone = &simulation.drone;
    // Commands are discrete actions and deliberately do not depend on frame time.
    switch (command) {
        .forward => drone.move(1.5, 0, 0),
        .backward => drone.move(-1.5, 0, 0),
        .left => drone.move(0, -1.5, 0),
        .right => drone.move(0, 1.5, 0),
        .up => drone.move(0, 0, 1),
        .down => drone.move(0, 0, -1),
        .rotate_left => drone.rotate(-22.5),
        .rotate_right => drone.rotate(22.5),
        .identify => return if (simulation.identify())
            "OK:identified"
        else
            "FAIL:no_creature_in_range",
        .screenshot, .state, .unknown => unreachable,
    }
    drone.constrain(&simulation.terrain);
    return "OK";
}

/// Position and distance always describe the same actual pose, not a requested target.
pub fn response(buffer: []u8, prefix: []const u8, simulation: *const Simulation) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const position = simulation.drone.position;
    writer.print("{s} x={d:.1} y={d:.1} z={d:.1} yaw={d:.1} remaining={d}", .{
        prefix, position.x, position.y, position.z, simulation.drone.yaw, simulation.terrain.creature_count,
    }) catch return "ERR";
    if (simulation.terrain.scenario != .legacy) return writer.buffered();
    writer.writeAll(" min_dist=") catch return "ERR";
    if (game.minDistanceToCreature(&simulation.terrain, position.x, position.y, position.z)) |distance| {
        writer.print("{d:.2}", .{distance}) catch return "ERR";
    } else writer.writeAll("none") catch return "ERR";
    return writer.buffered();
}

test "commands parse strictly and tolerate surrounding whitespace" {
    try std.testing.expectEqual(Command.forward, Command.parse(" forward\r\n"));
    try std.testing.expectEqual(Command.unknown, Command.parse("forward backward"));
    try std.testing.expectEqual(Command.unknown, Command.parse(""));
}

test "responses report actual position and completion remains queryable" {
    var simulation = Simulation.init(42, .legacy);
    const drone = &simulation.drone;
    var buffer: [128]u8 = undefined;
    const prefix = apply(.forward, &simulation);
    const reply = response(&buffer, prefix, &simulation);
    try std.testing.expect(std.mem.indexOf(u8, reply, "z=0.0") != null);
    try std.testing.expect(drone.target.z < drone.position.z);
    while (simulation.terrain.creature_count > 0) {
        const entry = simulation.terrain.creatures[0];
        simulation.terrain.removeCreature(entry.gx, entry.gz);
    }
    const target = drone.target;
    _ = apply(.forward, &simulation);
    try std.testing.expectEqualDeep(target, drone.target);
    try std.testing.expect(simulation.gameOver());
    try std.testing.expectEqual(game.total_creatures, simulation.creaturesFound());
    try std.testing.expectEqualStrings("OK:screenshot", apply(.screenshot, &simulation));
}

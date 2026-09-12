const std = @import("std");

pub const Options = struct {
    seed: ?u64 = null,
    fps: ?u16 = null,
    profile_frames: usize = 0,
    scenario: @import("terrain/world.zig").Scenario = .island,
    debug: bool = false,
    photo: bool = false,
    tour: bool = false,
    fast_agent: bool = false,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options: Options = .{};
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--fast-agent")) {
                options.fast_agent = true;
            } else if (std.mem.eql(u8, arg, "--debug")) {
                options.debug = true;
            } else if (std.mem.eql(u8, arg, "--photo")) {
                options.photo = true;
            } else if (std.mem.eql(u8, arg, "--tour")) {
                options.tour = true;
            } else if (std.mem.eql(u8, arg, "--scenario")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.scenario = std.meta.stringToEnum(@import("terrain/world.zig").Scenario, args[index]) orelse return error.InvalidScenario;
            } else if (std.mem.eql(u8, arg, "--fps") or std.mem.eql(u8, arg, "--profile")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                if (std.mem.eql(u8, arg, "--fps")) {
                    options.fps = try std.fmt.parseInt(u16, args[index], 10);
                } else {
                    options.profile_frames = try std.fmt.parseInt(usize, args[index], 10);
                    if (options.profile_frames == 0) return error.InvalidFrameCount;
                }
            } else if (options.seed == null) {
                options.seed = try std.fmt.parseInt(u64, arg, 10);
            } else return error.UnexpectedArgument;
        }
        return options;
    }
};

test "seed and profiling options parse independently" {
    const options = try Options.parse(&.{ "42", "--fps", "0", "--profile", "600" });
    try std.testing.expectEqual(@as(?u64, 42), options.seed);
    try std.testing.expectEqual(@as(?u16, 0), options.fps);
    try std.testing.expectEqual(600, options.profile_frames);
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{"--fps"}));
    try std.testing.expectError(error.InvalidFrameCount, Options.parse(&.{ "--profile", "0" }));
}

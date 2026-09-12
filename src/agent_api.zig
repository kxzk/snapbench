const std = @import("std");
const udp = @import("udp.zig");
const sim = @import("simulation.zig");
const world = @import("terrain/world.zig");
const protocol = @import("protocol.zig");
const camera = @import("camera.zig");
const Address = std.Io.net.IpAddress;

pub const Request = struct {
    id: u64,
    op: enum { reset, act, observe, state },
    seed: ?u64 = null,
    scenario: ?world.Scenario = null,
    command: ?sim.Action = null,
    ticks: u16 = 30,

    pub fn validate(self: Request) !void {
        if (self.id == 0 or self.id > 9007199254740991) return error.InvalidRequestId;
        if (self.op == .act and (self.command == null or self.ticks == 0 or self.ticks > 2400)) return error.InvalidAction;
        if (self.op != .act and self.command != null) return error.UnexpectedCommand;
        if (self.op != .reset and (self.seed != null or self.scenario != null)) return error.UnexpectedResetOptions;
    }
};

const Pending = struct {
    client: Address,
    protocol: union(enum) { legacy, json: struct { id: u64, hash: u64 } },
    work: union(enum) {
        action: struct { command: sim.Action, remaining: u16, accumulator: f64 = 0 },
        capture,
        encoding: Reply,
    },
};
const Reply = struct {
    buffer: [1024]u8 = undefined,
    len: usize = 0,
};
const Cached = struct {
    id: u64 = 0,
    hash: u64 = 0,
    reply: Reply = .{},
};

pub const AgentApi = struct {
    server: udp.UdpServer,
    allocator: std.mem.Allocator,
    owner: ?Address = null,
    last_id: u64 = 0,
    pending: ?Pending = null,
    cache: [32]Cached = .{Cached{}} ** 32,
    cache_index: usize = 0,
    session: u64,
    episode: u64 = 0,
    fast_actions: bool = false,
    image_path: [192:0]u8 = undefined,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, session: u64) !AgentApi {
        return .{ .server = try udp.UdpServer.init(io, 9999), .allocator = allocator, .session = session };
    }
    pub fn deinit(self: *AgentApi) void {
        self.server.deinit();
    }

    pub fn cancel(self: *AgentApi) void {
        if (self.pending) |pending| {
            switch (pending.protocol) {
                .json => |request| self.reject(pending.client, request.id, "canceled"),
                .legacy => self.server.send("FAIL:canceled", pending.client),
            }
        }
        self.pending = null;
        self.owner = null;
    }

    /// Returns true when a reset requires rebuilding the scene's GPU resources.
    pub fn poll(self: *AgentApi, simulation: *sim.Simulation, seconds: f64) !bool {
        if (self.pending) |*pending| {
            switch (pending.work) {
                .action => |*action| {
                    action.accumulator += std.math.clamp(seconds, 0, 0.1);
                    const available: u16 = if (self.fast_actions) 32 else @intFromFloat(@floor(action.accumulator / sim.tick_seconds));
                    const steps = @min(action.remaining, available);
                    action.accumulator = if (self.fast_actions) 0 else @max(action.accumulator - @as(f64, @floatFromInt(steps)) * sim.tick_seconds, 0);
                    for (0..steps) |_| simulation.step(sim.Input.action(action.command));
                    action.remaining -= steps;
                    if (action.remaining == 0) {
                        const status: []const u8 = if (action.command == .identify)
                            (if (simulation.identify()) "identified" else "no_subject")
                        else
                            "ok";
                        self.finish(simulation, status);
                    }
                },
                .capture, .encoding => {},
            }
            return false;
        }
        var buffer: [1024]u8 = undefined;
        for (0..16) |_| {
            const message = (try self.server.tryRecv(&buffer)) orelse break;
            if (message.flags.trunc) {
                self.server.send("FAIL:truncated", message.from);
                continue;
            }
            if (message.data.len == 0 or message.data[0] != '{') {
                const command = protocol.Command.parse(message.data);
                if (command == .screenshot) {
                    self.pending = .{ .client = message.from, .protocol = .legacy, .work = .capture };
                    _ = try std.fmt.bufPrintZ(&self.image_path, "screenshot.png", .{});
                    break;
                }
                const prefix = if (command == .state) "OK" else if (simulation.externally_clocked) "FAIL:agent_control" else protocol.apply(command, simulation);
                var reply: [128]u8 = undefined;
                // Exact distance remains available only in the explicitly named legacy scenario.
                self.server.send(protocol.response(&reply, prefix, simulation), message.from);
                continue;
            }
            const parsed = std.json.parseFromSlice(Request, self.allocator, message.data, .{}) catch {
                self.reject(message.from, 0, "invalid_request");
                continue;
            };
            defer parsed.deinit();
            const request = parsed.value;
            request.validate() catch {
                self.reject(message.from, request.id, "invalid_request");
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, message.data);
            const owns = if (self.owner) |owner| std.meta.eql(owner, message.from) else false;
            if (owns) {
                var cached = false;
                for (&self.cache) |*entry| {
                    if (entry.id != request.id) continue;
                    if (entry.hash == hash) self.server.send(entry.reply.buffer[0..entry.reply.len], message.from) else self.reject(message.from, request.id, "id_conflict");
                    cached = true;
                    break;
                }
                if (cached) continue;
                if (request.id <= self.last_id) {
                    self.reject(message.from, request.id, "stale_id");
                    continue;
                }
            } else {
                if (request.op != .reset) {
                    self.reject(message.from, request.id, "reset_required");
                    continue;
                }
                self.owner = message.from;
                self.last_id = 0;
                self.cache = .{Cached{}} ** 32;
                self.cache_index = 0;
            }
            self.last_id = request.id;
            self.pending = .{ .client = message.from, .protocol = .{ .json = .{ .id = request.id, .hash = hash } }, .work = .capture };
            switch (request.op) {
                .reset => {
                    simulation.* = sim.Simulation.init(request.seed orelse simulation.seed, request.scenario orelse simulation.terrain.scenario);
                    simulation.externally_clocked = true;
                    self.episode += 1;
                    self.finish(simulation, "ok");
                    return true;
                },
                .act => {
                    self.pending.?.work = .{ .action = .{ .command = request.command.?, .remaining = request.ticks } };
                },
                .state => self.finish(simulation, "ok"),
                .observe => {
                    _ = try std.fmt.bufPrintZ(&self.image_path, ".snapbench/observations/{x}-{d}-{d}.png", .{ self.session, self.episode, request.id });
                },
            }
            if (self.pending != null) break;
        }
        return false;
    }

    pub fn wantsCapture(self: *const AgentApi) bool {
        const pending = self.pending orelse return false;
        return pending.work == .capture;
    }

    pub fn captured(self: *AgentApi, simulation: *const sim.Simulation) void {
        const pending = &self.pending.?;
        std.debug.assert(pending.work == .capture);
        var reply: Reply = .{};
        reply.len = switch (pending.protocol) {
            .json => |request| response(&reply.buffer, request.id, simulation, "ok", std.mem.sliceTo(&self.image_path, 0)).len,
            .legacy => protocol.response(&reply.buffer, "OK:screenshot", simulation).len,
        };
        pending.work = .{ .encoding = reply };
    }

    pub fn completeCapture(self: *AgentApi, succeeded: bool) void {
        if (!succeeded) {
            var reply: Reply = .{};
            reply.len = switch (self.pending.?.protocol) {
                .json => |request| rejection(&reply.buffer, request.id, "capture_failed").len,
                .legacy => (std.fmt.bufPrint(&reply.buffer, "FAIL:screenshot", .{}) catch unreachable).len,
            };
            self.deliver(reply);
            return;
        }
        self.deliver(self.pending.?.work.encoding);
    }

    fn finish(self: *AgentApi, simulation: *const sim.Simulation, status: []const u8) void {
        var reply: Reply = .{};
        reply.len = response(&reply.buffer, self.pending.?.protocol.json.id, simulation, status, null).len;
        self.deliver(reply);
    }
    fn deliver(self: *AgentApi, reply: Reply) void {
        const pending = &self.pending.?;
        self.server.send(reply.buffer[0..reply.len], pending.client);
        switch (pending.protocol) {
            .json => |request| {
                self.cache[self.cache_index] = .{ .id = request.id, .hash = request.hash, .reply = reply };
                self.cache_index = (self.cache_index + 1) % self.cache.len;
            },
            .legacy => {},
        }
        self.pending = null;
    }
    fn reject(self: *AgentApi, client: Address, id: u64, reason: []const u8) void {
        var buffer: [128]u8 = undefined;
        self.server.send(rejection(&buffer, id, reason), client);
    }
};

fn rejection(buffer: []u8, id: u64, reason: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{{\"version\":2,\"id\":{d},\"status\":\"{s}\"}}", .{ id, reason }) catch unreachable;
}

pub fn response(buffer: []u8, id: u64, simulation: *const sim.Simulation, status: []const u8, image: ?[]const u8) []const u8 {
    const d = simulation.drone;
    const pose = [_]f32{ d.position.x, d.position.y, d.position.z, d.target.x, d.target.y, d.target.z, d.yaw, d.visual_yaw, d.pitch };
    const world_hash = std.hash.Wyhash.hash(simulation.seed, std.mem.asBytes(&simulation.terrain.cells));
    const hash = std.hash.Wyhash.hash(simulation.tick ^ world_hash, std.mem.asBytes(&pose));
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("{{\"version\":2,\"id\":{d},\"scenario\":\"{s}\",\"seed\":{d},\"tick\":{d},\"state_hash\":\"{x}\",\"status\":\"{s}\",\"x\":{d:.6},\"y\":{d:.6},\"z\":{d:.6},\"yaw\":{d:.6},\"pitch\":{d:.6},\"remaining\":{d},\"image\":", .{
        id,           if (simulation.terrain.scenario == .island) @as([]const u8, "island-photo-v2") else "legacy-proximity-v1", simulation.seed, simulation.tick, hash,    status,
        d.position.x, d.position.y,                                                                                              d.position.z,    d.visual_yaw,    d.pitch, simulation.terrain.creature_count,
    }) catch return "ERR";
    if (image) |path| writer.print("\"{s}\"", .{path}) catch return "ERR" else writer.writeAll("null") catch return "ERR";
    writer.print(",\"sensor\":{{\"width\":{d},\"height\":{d},\"fov_y\":60}},\"tick_rate\":120}}", .{ camera.sensor_width, camera.sensor_height }) catch return "ERR";
    return writer.buffered();
}

test "API validates bounded actions and responses contain no privileged distance" {
    try std.testing.expectError(error.InvalidAction, (Request{ .id = 1, .op = .act, .command = .forward, .ticks = 0 }).validate());
    try std.testing.expectError(error.InvalidRequestId, (Request{ .id = 0, .op = .state }).validate());
    const simulation = sim.Simulation.init(42, .island);
    var buffer: [1024]u8 = undefined;
    const reply = response(&buffer, 1, &simulation, "ok", null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "min_dist") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("tick").?.integer);
}

fn testExchange(api: *AgentApi, client: *udp.UdpServer, simulation: *sim.Simulation, request: []const u8, buffer: []u8) ![]const u8 {
    try client.socket.send(client.io, &api.server.socket.address, request);
    for (0..1000) |_| {
        _ = try api.poll(simulation, 1.0 / 60.0);
        if (try client.tryRecv(buffer)) |reply| return reply.data;
        try std.Io.sleep(client.io, .fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

test "retries cannot replay an action and conflicting IDs are rejected" {
    var api: AgentApi = .{ .server = try udp.UdpServer.init(std.testing.io, 0), .allocator = std.testing.allocator, .session = 1, .fast_actions = true };
    defer api.deinit();
    var client = try udp.UdpServer.init(std.testing.io, 0);
    defer client.deinit();
    var simulation = sim.Simulation.init(42, .island);
    var buffer: [1024]u8 = undefined;
    _ = try testExchange(&api, &client, &simulation, "{\"id\":1,\"op\":\"reset\",\"seed\":42}", &buffer);
    const request = "{\"id\":2,\"op\":\"act\",\"command\":\"forward\",\"ticks\":30}";
    const original = try std.testing.allocator.dupe(u8, try testExchange(&api, &client, &simulation, request, &buffer));
    defer std.testing.allocator.free(original);
    try std.testing.expectEqual(@as(u64, 30), simulation.tick);
    try std.testing.expectEqualStrings(original, try testExchange(&api, &client, &simulation, request, &buffer));
    try std.testing.expectEqual(@as(u64, 30), simulation.tick);
    const conflict = try testExchange(&api, &client, &simulation, "{\"id\":2,\"op\":\"act\",\"command\":\"backward\",\"ticks\":30}", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, conflict, "id_conflict") != null);
    try std.testing.expectEqual(@as(u64, 30), simulation.tick);
}

test "capture failures are cached before and after readback starts" {
    for ([_]bool{ false, true }) |encoding| {
        var api: AgentApi = .{ .server = try udp.UdpServer.init(std.testing.io, 0), .allocator = std.testing.allocator, .session = 1 };
        defer api.deinit();
        var client = try udp.UdpServer.init(std.testing.io, 0);
        defer client.deinit();
        var simulation = sim.Simulation.init(42, .island);
        var buffer: [1024]u8 = undefined;
        _ = try testExchange(&api, &client, &simulation, "{\"id\":1,\"op\":\"reset\"}", &buffer);
        const request = "{\"id\":2,\"op\":\"observe\"}";
        try client.socket.send(client.io, &api.server.socket.address, request);
        for (0..1000) |_| {
            _ = try api.poll(&simulation, 1.0 / 60.0);
            if (api.wantsCapture()) break;
            try std.Io.sleep(client.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(api.wantsCapture());
        if (encoding) {
            api.captured(&simulation);
            try std.testing.expect(!api.wantsCapture());
        }
        api.completeCapture(false);
        const failed = try client.socket.receiveTimeout(client.io, &buffer, .{
            .duration = .{ .raw = .fromSeconds(1), .clock = .awake },
        });
        const expected = "{\"version\":2,\"id\":2,\"status\":\"capture_failed\"}";
        try std.testing.expectEqualStrings(expected, failed.data);
        try std.testing.expectEqualStrings(expected, try testExchange(&api, &client, &simulation, request, &buffer));
        try std.testing.expect(api.pending == null);
        try std.testing.expectEqual(@as(u64, 0), simulation.tick);
        _ = try testExchange(&api, &client, &simulation, "{\"id\":3,\"op\":\"state\"}", &buffer);
    }
}

test "capture replies retain the captured pose until encoding finishes" {
    var api: AgentApi = .{ .server = try udp.UdpServer.init(std.testing.io, 0), .allocator = std.testing.allocator, .session = 1 };
    defer api.deinit();
    var client = try udp.UdpServer.init(std.testing.io, 0);
    defer client.deinit();
    var simulation = sim.Simulation.init(42, .island);
    api.pending = .{ .client = client.socket.address, .protocol = .{ .json = .{ .id = 1, .hash = 1 } }, .work = .capture };
    _ = try std.fmt.bufPrintZ(&api.image_path, "screenshot.png", .{});
    api.captured(&simulation);
    simulation.step(.{ .forward = 1 });
    api.completeCapture(true);
    var buffer: [1024]u8 = undefined;
    const reply = try client.socket.receiveTimeout(client.io, &buffer, .{
        .duration = .{ .raw = .fromSeconds(1), .clock = .awake },
    });
    try std.testing.expect(std.mem.indexOf(u8, reply.data, "\"tick\":0,") != null);
    try std.testing.expect(api.pending == null);
}

test "invalid requests and previous owners cannot change simulation state" {
    var api: AgentApi = .{ .server = try udp.UdpServer.init(std.testing.io, 0), .allocator = std.testing.allocator, .session = 1, .fast_actions = true };
    defer api.deinit();
    var client = try udp.UdpServer.init(std.testing.io, 0);
    defer client.deinit();
    var next_owner = try udp.UdpServer.init(std.testing.io, 0);
    defer next_owner.deinit();
    var simulation = sim.Simulation.init(42, .island);
    var buffer: [1024]u8 = undefined;
    _ = try testExchange(&api, &client, &simulation, "{\"id\":1,\"op\":\"reset\"}", &buffer);
    const invalid = try testExchange(&api, &client, &simulation, "{\"id\":2,\"op\":\"act\",\"command\":\"forward\",\"ticks\":2401}", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "invalid_request") != null);
    _ = try testExchange(&api, &next_owner, &simulation, "{\"id\":1,\"op\":\"reset\",\"seed\":72}", &buffer);
    const rejected = try testExchange(&api, &client, &simulation, "{\"id\":2,\"op\":\"act\",\"command\":\"forward\"}", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "reset_required") != null);
    try std.testing.expectEqual(@as(u64, 0), simulation.tick);
    try std.testing.expectEqual(@as(u64, 72), simulation.seed);
}

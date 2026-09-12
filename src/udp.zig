const std = @import("std");
const Io = std.Io;
const net = Io.net;

pub const UdpServer = struct {
    socket: net.Socket,
    io: Io,

    pub fn init(io: Io, port: u16) !UdpServer {
        const address: net.IpAddress = .{ .ip4 = .loopback(port) };
        return .{
            .socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp }),
            .io = io,
        };
    }

    pub fn deinit(self: *UdpServer) void {
        self.socket.close(self.io);
    }

    /// A zero timeout polls the socket without blocking the render loop.
    pub fn tryRecv(self: *UdpServer, buffer: []u8) !?net.IncomingMessage {
        return self.socket.receiveTimeout(self.io, buffer, .{
            .duration = .{ .raw = .zero, .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => null,
            else => return err,
        };
    }

    pub fn send(self: *UdpServer, data: []const u8, client: net.IpAddress) void {
        self.socket.send(self.io, &client, data) catch |err| {
            std.log.warn("UDP send failed: {t}", .{err});
        };
    }
};

test "UDP polling is nonblocking and round trips a datagram" {
    const io = std.testing.io;
    var server = try UdpServer.init(io, 0);
    defer server.deinit();
    var client = try UdpServer.init(io, 0);
    defer client.deinit();
    var buffer: [256]u8 = undefined;
    try std.testing.expect(try server.tryRecv(&buffer) == null);
    try client.socket.send(io, &server.socket.address, "forward");
    const message = try server.socket.receiveTimeout(io, &buffer, .{
        .duration = .{ .raw = .fromSeconds(1), .clock = .awake },
    });
    try std.testing.expectEqualStrings("forward", message.data);
    server.send("OK", message.from);
    const reply = try client.socket.receiveTimeout(io, &buffer, .{
        .duration = .{ .raw = .fromSeconds(1), .clock = .awake },
    });
    try std.testing.expectEqualStrings("OK", reply.data);
    try std.testing.expect(try server.tryRecv(&buffer) == null);
}

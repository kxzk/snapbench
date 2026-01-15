const std = @import("std");
const posix = std.posix;

pub const ClientAddr = struct {
    addr: posix.sockaddr,
    len: posix.socklen_t,
};

pub const RecvResult = struct {
    data: []u8,
    client: ClientAddr,
};

pub const UdpServer = struct {
    socket: posix.socket_t,

    pub fn init() !UdpServer {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(sock);

        const addr = posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, 9999),
            .addr = 0,
        };

        try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        return .{ .socket = sock };
    }

    pub fn deinit(self: *UdpServer) void {
        posix.close(self.socket);
    }

    pub fn tryRecv(self: *UdpServer, buf: []u8) ?RecvResult {
        var client_addr: posix.sockaddr = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const result = posix.recvfrom(self.socket, buf, 0, &client_addr, &client_len);

        if (result) |bytes_read| {
            return .{
                .data = buf[0..bytes_read],
                .client = .{ .addr = client_addr, .len = client_len },
            };
        } else |_| {
            return null;
        }
    }

    pub fn send(self: *UdpServer, data: []const u8, client: ClientAddr) void {
        _ = posix.sendto(self.socket, data, 0, &client.addr, client.len) catch |err| {
            std.log.warn("UDP send failed: {}", .{err});
        };
    }
};

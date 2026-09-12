const std = @import("std");
const rl = @import("rl.zig").c;
const gl = @cImport({
    @cInclude("external/glad.h");
});

// Use raylib's already loaded, typed GLAD procedures on every desktop OS.
// raylib 6's rlGetProcAddress casts GLFW's function-pointer return type to void*,
// which trips the C function-type sanitizer in Zig ReleaseSafe builds.
// A fence keeps GPU readback off the blocking path; PNG work stays on a worker.
const Gl = struct {
    GenBuffers: *const fn (c_int, *c_uint) callconv(.c) void,
    DeleteBuffers: *const fn (c_int, *const c_uint) callconv(.c) void,
    BindBuffer: *const fn (c_uint, c_uint) callconv(.c) void,
    BufferData: *const fn (c_uint, isize, ?*const anyopaque, c_uint) callconv(.c) void,
    ReadPixels: *const fn (c_int, c_int, c_int, c_int, c_uint, c_uint, ?*anyopaque) callconv(.c) void,
    FenceSync: *const fn (c_uint, c_uint) callconv(.c) ?*anyopaque,
    ClientWaitSync: *const fn (*anyopaque, c_uint, u64) callconv(.c) c_uint,
    DeleteSync: *const fn (*anyopaque) callconv(.c) void,
    MapBufferRange: *const fn (c_uint, isize, isize, c_uint) callconv(.c) ?*anyopaque,
    UnmapBuffer: *const fn (c_uint) callconv(.c) u8,
    Flush: *const fn () callconv(.c) void,

    fn init() !Gl {
        var api: Gl = undefined;
        inline for (std.meta.fields(Gl)) |field| {
            @field(api, field.name) = @ptrCast(@field(gl, "glad_gl" ++ field.name) orelse return error.MissingReadbackProcedure);
        }
        return api;
    }
};
const pixel_pack_buffer = 0x88EB;

pub const Screenshot = struct {
    gl: Gl,
    buffer: c_uint = 0,
    capacity: usize = 0,
    fence: ?*anyopaque = null,
    thread: ?std.Thread = null,
    image: rl.Image = undefined,
    path: [192:0]u8 = undefined,
    finished: std.atomic.Value(bool) = .init(false),
    succeeded: bool = false,

    pub fn init() !Screenshot {
        var self: Screenshot = .{ .gl = try Gl.init() };
        self.gl.GenBuffers(1, &self.buffer);
        if (self.buffer == 0) return error.ReadbackBufferUnavailable;
        return self;
    }

    pub fn busy(self: *const Screenshot) bool {
        return self.fence != null or self.thread != null;
    }

    /// The caller binds and finishes drawing the dedicated observation framebuffer.
    pub fn start(self: *Screenshot, path: []const u8, width: c_int, height: c_int) !void {
        std.debug.assert(!self.busy());
        _ = try std.fmt.bufPrintZ(&self.path, "{s}", .{path});
        const size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        self.image = .{ .data = null, .width = width, .height = height, .mipmaps = 1, .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8 };
        self.gl.BindBuffer(pixel_pack_buffer, self.buffer);
        defer self.gl.BindBuffer(pixel_pack_buffer, 0);
        if (size != self.capacity) {
            self.gl.BufferData(pixel_pack_buffer, @intCast(size), null, 0x88E1); // GL_STREAM_READ
            self.capacity = size;
        }
        self.gl.ReadPixels(0, 0, width, height, 0x1908, 0x1401, null); // RGBA / unsigned byte
        self.fence = self.gl.FenceSync(0x9117, 0) orelse return error.ReadbackFenceUnavailable;
        self.gl.Flush();
    }

    fn encode(self: *Screenshot) void {
        rl.ImageFlipVertical(&self.image);
        self.succeeded = rl.ExportImage(self.image, &self.path);
        rl.UnloadImage(self.image);
        self.finished.store(true, .release);
    }

    pub fn poll(self: *Screenshot) !?bool {
        if (self.fence) |fence| {
            const status = self.gl.ClientWaitSync(fence, 0, 0);
            if (status == 0x911B) return null; // GL_TIMEOUT_EXPIRED, never wait on the render thread
            self.gl.DeleteSync(fence);
            self.fence = null;
            if (status != 0x911A and status != 0x911C) return error.ReadbackWaitFailed;
            self.image.data = rl.MemAlloc(@intCast(self.capacity)) orelse return error.OutOfMemory;
            errdefer rl.UnloadImage(self.image);
            self.gl.BindBuffer(pixel_pack_buffer, self.buffer);
            defer self.gl.BindBuffer(pixel_pack_buffer, 0);
            const mapped = self.gl.MapBufferRange(pixel_pack_buffer, 0, @intCast(self.capacity), 1) orelse return error.ReadbackMapFailed;
            @memcpy(@as([*]u8, @ptrCast(self.image.data))[0..self.capacity], @as([*]const u8, @ptrCast(mapped))[0..self.capacity]);
            if (self.gl.UnmapBuffer(pixel_pack_buffer) == 0) return error.ReadbackCorrupted;
            self.finished.store(false, .monotonic);
            self.thread = try std.Thread.spawn(.{}, encode, .{self});
        }
        const thread = self.thread orelse return null;
        if (!self.finished.load(.acquire)) return null;
        thread.join();
        self.thread = null;
        return self.succeeded;
    }

    pub fn deinit(self: *Screenshot) void {
        if (self.thread) |thread| thread.join();
        if (self.fence) |fence| self.gl.DeleteSync(fence);
        self.gl.DeleteBuffers(1, &self.buffer);
    }
};

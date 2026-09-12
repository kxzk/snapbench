const std = @import("std");

/// Records completed frames, including presentation and frame pacing.
pub const FrameProfile = struct {
    frame_ms: []f64,
    work_ms: []f64,
    warmup_remaining: usize = 120,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, frames: usize) !FrameProfile {
        const frame_ms = try allocator.alloc(f64, frames);
        errdefer allocator.free(frame_ms);
        return .{ .frame_ms = frame_ms, .work_ms = try allocator.alloc(f64, frames) };
    }

    pub fn deinit(self: *FrameProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.frame_ms);
        allocator.free(self.work_ms);
    }

    pub fn record(self: *FrameProfile, frame_seconds: f32, work_seconds: f64) bool {
        if (self.frame_ms.len == 0) return false;
        if (self.warmup_remaining > 0) {
            self.warmup_remaining -= 1;
            return false;
        }
        self.frame_ms[self.count] = @as(f64, frame_seconds) * 1000;
        self.work_ms[self.count] = work_seconds * 1000;
        self.count += 1;
        return self.count == self.frame_ms.len;
    }

    pub fn report(self: *FrameProfile) void {
        if (self.count == 0) return;
        const frames = self.frame_ms[0..self.count];
        const work = self.work_ms[0..self.count];
        std.mem.sort(f64, frames, {}, std.sort.asc(f64));
        std.mem.sort(f64, work, {}, std.sort.asc(f64));
        var total: f64 = 0;
        var slow_frames: usize = 0;
        for (frames) |ms| {
            total += ms;
            if (ms > 1000.0 / 60.0) slow_frames += 1;
        }
        std.debug.print("PROFILE frames={d} fps={d:.1} frame_ms_p50={d:.3} p95={d:.3} p99={d:.3} max={d:.3} work_ms_p95={d:.3} over_16.67ms={d}\n", .{
            self.count,             1000 * @as(f64, @floatFromInt(self.count)) / total,
            percentile(frames, 50), percentile(frames, 95),
            percentile(frames, 99), frames[frames.len - 1],
            percentile(work, 95),   slow_frames,
        });
    }
};

fn percentile(sorted: []const f64, percent: usize) f64 {
    return sorted[(sorted.len - 1) * percent / 100];
}

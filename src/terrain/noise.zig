const std = @import("std");

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(t: f32, a: f32, b: f32) f32 {
    return a + t * (b - a);
}

fn grad(hash: u8, x: f32, y: f32) f32 {
    const h = hash & 3;
    const u = if (h < 2) x else y;
    const v = if (h < 2) y else x;
    return (if ((h & 1) == 0) u else -u) + (if ((h & 2) == 0) v else -v);
}

pub const PerlinNoise = struct {
    perm: [512]u8,

    pub fn init(seed: u64) PerlinNoise {
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();

        var p: [256]u8 = undefined;
        for (0..256) |i| p[i] = @intCast(i);

        var i: usize = 255;
        while (i > 0) : (i -= 1) {
            const j = random.uintLessThan(usize, i + 1);
            const tmp = p[i];
            p[i] = p[j];
            p[j] = tmp;
        }

        var perm: [512]u8 = undefined;
        for (0..512) |idx| perm[idx] = p[idx & 255];
        return .{ .perm = perm };
    }

    pub fn sample2D(self: *const PerlinNoise, x: f32, y: f32) f32 {
        const xi: usize = @intCast(@as(i32, @intFromFloat(@floor(x))) & 255);
        const yi: usize = @intCast(@as(i32, @intFromFloat(@floor(y))) & 255);
        const xf = x - @floor(x);
        const yf = y - @floor(y);
        const u = fade(xf);
        const v = fade(yf);

        const aa = self.perm[self.perm[xi] +% yi];
        const ab = self.perm[self.perm[xi] +% yi +% 1];
        const ba = self.perm[self.perm[xi +% 1] +% yi];
        const bb = self.perm[self.perm[xi +% 1] +% yi +% 1];

        const x1 = lerp(u, grad(aa, xf, yf), grad(ba, xf - 1, yf));
        const x2 = lerp(u, grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1));
        return lerp(v, x1, x2);
    }

    pub fn octaveNoise(self: *const PerlinNoise, x: f32, y: f32, octaves: u32, persistence: f32) f32 {
        var total: f32 = 0;
        var frequency: f32 = 1;
        var amplitude: f32 = 1;
        var max_value: f32 = 0;

        for (0..octaves) |_| {
            total += self.sample2D(x * frequency, y * frequency) * amplitude;
            max_value += amplitude;
            amplitude *= persistence;
            frequency *= 2;
        }
        return total / max_value;
    }
};

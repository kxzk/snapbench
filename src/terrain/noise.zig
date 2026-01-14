const std = @import("std");

/// Quintic smoothstep (6t^5 - 15t^4 + 10t^3). Ken Perlin's improved fade function.
/// Produces smoother gradients than the original cubic by having zero first AND second
/// derivatives at 0 and 1, eliminating visible grid artifacts.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Standard linear interpolation. Returns a when t=0, b when t=1.
fn lerp(t: f32, a: f32, b: f32) f32 {
    return a + t * (b - a);
}

/// Computes gradient dot product for 2D Perlin noise.
/// Uses the low 2 bits of hash to select one of four gradient directions,
/// then dots that gradient with the offset vector (x,y) from grid corner.
fn grad(hash: u8, x: f32, y: f32) f32 {
    const h = hash & 3;
    const u = if (h < 2) x else y;
    const v = if (h < 2) y else x;
    return (if ((h & 1) == 0) u else -u) + (if ((h & 2) == 0) v else -v);
}

pub const PerlinNoise = struct {
    perm: [512]u8,

    /// Initializes the permutation table using Fisher-Yates shuffle.
    /// The 512-entry table (256 values doubled) avoids modulo in lookups.
    /// Seeding ensures reproducible noise for the same world seed.
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

    /// Samples 2D Perlin noise at (x,y), returning a value in approximately [-1, 1].
    /// Finds the enclosing grid cell, computes gradient contributions from all four
    /// corners, and bilinearly interpolates using the smoothed fractional position.
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

    /// Generates fractal Brownian motion (fBm) by summing multiple noise octaves.
    /// Each octave doubles in frequency and decreases in amplitude by persistence factor.
    /// More octaves add fine detail; persistence < 1 makes higher octaves subtler.
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

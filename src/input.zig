const rl = @import("rl.zig").c;
const Input = @import("simulation.zig").Input;

pub const Keyboard = struct {
    pressed: [rl.KEY_KB_MENU + 1]bool = .{false} ** (rl.KEY_KB_MENU + 1),
    pub fn collect(self: *Keyboard) void {
        while (true) {
            const key = rl.GetKeyPressed();
            if (key == 0) break;
            if (key > 0 and key < self.pressed.len) self.pressed[@intCast(key)] = true;
        }
    }
    pub fn clear(self: *Keyboard) void {
        self.* = .{};
    }
    pub fn takePress(self: *Keyboard, key: c_int) bool {
        const index: usize = @intCast(key);
        const pressed = self.pressed[index] or rl.IsKeyPressed(key);
        self.pressed[index] = false;
        return pressed;
    }
    fn down(self: Keyboard, key: c_int) f32 {
        return @floatFromInt(@intFromBool(self.pressed[@intCast(key)] or rl.IsKeyDown(key)));
    }
    pub fn input(self: Keyboard) Input {
        return .{ .forward = @max(self.down(rl.KEY_W), self.down(rl.KEY_UP)) - @max(self.down(rl.KEY_S), self.down(rl.KEY_DOWN)), .right = @max(self.down(rl.KEY_D), self.down(rl.KEY_RIGHT)) - @max(self.down(rl.KEY_A), self.down(rl.KEY_LEFT)), .up = self.down(rl.KEY_SPACE) - self.down(rl.KEY_LEFT_SHIFT), .turn = self.down(rl.KEY_E) - self.down(rl.KEY_Q), .look = self.down(rl.KEY_I) - self.down(rl.KEY_K) };
    }
};

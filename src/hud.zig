const rl = @import("rl.zig").c;
const Simulation = @import("simulation.zig").Simulation;
const camera = @import("camera.zig");
const game = @import("game_state.zig");

const ink: rl.Color = .{ .r = 247, .g = 250, .b = 252, .a = 255 };
const secondary: rl.Color = .{ .r = 210, .g = 225, .b = 231, .a = 255 };
const panel: rl.Color = .{ .r = 14, .g = 29, .b = 35, .a = 250 };
const key_background: rl.Color = .{ .r = 46, .g = 69, .b = 78, .a = 255 };
const accent: rl.Color = .{ .r = 255, .g = 225, .b = 145, .a = 255 };

const TextSize = enum { control, body, value, title };
const font_sizes = [_]c_int{ 18, 22, 28, 34 };
const letter_spacing = 1;

pub const Hud = struct {
    fonts: [font_sizes.len]rl.Font,
    debug: bool = false,
    notice_until: f64 = 0,
    identified: bool = false,

    pub fn init() !Hud {
        var fonts: [font_sizes.len]rl.Font = undefined;
        var loaded: usize = 0;
        errdefer for (fonts[0..loaded]) |font| rl.UnloadFont(font);
        for (font_sizes, 0..) |size, index| {
            const font = rl.LoadFontEx("assets/fonts/Manrope.ttf", size, null, 0);
            if (!rl.IsFontValid(font) or font.texture.id == rl.GetFontDefault().texture.id) return error.MissingInterfaceFont;
            // Rasterize at the displayed size. Shrinking a large atlas blurs
            // small letters; integer placement preserves these native pixels.
            rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_POINT);
            fonts[index] = font;
            loaded += 1;
        }
        return .{ .fonts = fonts };
    }

    pub fn deinit(self: Hud) void {
        for (self.fonts) |font| rl.UnloadFont(font);
    }

    fn text(self: Hud, value: [*c]const u8, x: f32, y: f32, size: TextSize, color: rl.Color) void {
        const font = self.fonts[@intFromEnum(size)];
        rl.DrawTextEx(font, value, .{ .x = @round(x), .y = @round(y) }, @floatFromInt(font.baseSize), letter_spacing, color);
    }

    fn textWidth(self: Hud, value: [*c]const u8, size: TextSize) f32 {
        const font = self.fonts[@intFromEnum(size)];
        return rl.MeasureTextEx(font, value, @floatFromInt(font.baseSize), letter_spacing).x;
    }

    fn centeredText(self: Hud, value: [*c]const u8, center: f32, y: f32, size: TextSize, color: rl.Color) void {
        self.text(value, center - self.textWidth(value, size) * 0.5, y, size, color);
    }

    fn card(x: f32, y: f32, width: f32, height: f32) void {
        rl.DrawRectangleRounded(.{ .x = x, .y = y, .width = width, .height = height }, 0.1, 8, panel);
    }

    fn control(self: Hud, keys: [:0]const u8, label: [:0]const u8, x: f32, y: f32) void {
        const key_width = self.textWidth(keys, .control) + 16;
        rl.DrawRectangleRounded(.{ .x = x, .y = y, .width = key_width, .height = 28 }, 0.2, 6, key_background);
        self.text(keys, x + 8, y + 5, .control, ink);
        self.text(label, x + key_width + 10, y + 5, .control, ink);
    }

    fn drawControls(self: Hud, width: f32, height: f32) void {
        const controls = [_]struct { keys: [:0]const u8, label: [:0]const u8 }{
            .{ .keys = "WASD", .label = "Fly" },
            .{ .keys = "Q / E", .label = "Turn" },
            .{ .keys = "Space / Shift", .label = "Altitude" },
            .{ .keys = "I / K", .label = "Camera tilt" },
            .{ .keys = "Tab", .label = "Camera" },
            .{ .keys = "P", .label = "Photograph" },
            .{ .keys = "R", .label = "Reset" },
            .{ .keys = "F3", .label = "Stats" },
        };
        const panel_width = @min(width - 48, 1080);
        const panel_x = (width - panel_width) * 0.5;
        card(panel_x, height - 108, panel_width, 84);
        const column_width = (panel_width - 32) / 4;
        for (controls, 0..) |item, index| {
            self.control(item.keys, item.label, panel_x + 16 + @as(f32, @floatFromInt(index % 4)) * column_width, height - 98 + @as(f32, @floatFromInt(index / 4)) * 36);
        }
    }

    pub fn notify(self: *Hud, identified: bool) void {
        self.identified = identified;
        self.notice_until = rl.GetTime() + 4;
    }

    pub fn draw(self: Hud, simulation: *const Simulation, mode: camera.Mode, chunks: usize) void {
        const width: f32 = @floatFromInt(rl.GetScreenWidth());
        const height: f32 = @floatFromInt(rl.GetScreenHeight());
        const center = width * 0.5;
        card(24, 24, 330, 112);
        self.text("SnapBench", 44, 40, .body, secondary);
        self.text(if (simulation.terrain.scenario == .island) "Mariner Island" else "Legacy Reserve", 44, 76, .title, ink);
        card(width - 284, 24, 260, 112);
        self.text("Species found", width - 264, 40, .body, secondary);
        self.text(rl.TextFormat("%d / 3", @as(c_int, @intCast(simulation.creaturesFound()))), width - 264, 76, .title, accent);
        self.drawControls(width, height);

        if (mode == .photo) {
            var ready = false;
            for (simulation.terrain.creatures[0..simulation.terrain.creature_count]) |entry| {
                ready = ready or game.photographable(&simulation.terrain, entry.gx, entry.gz, camera.sensor(simulation.drone));
            }
            const color = if (ready) accent else ink;
            const cx: c_int = @intFromFloat(center);
            const cy: c_int = @intFromFloat(height * 0.5);
            rl.DrawLine(cx - 12, cy, cx - 4, cy, color);
            rl.DrawLine(cx + 4, cy, cx + 12, cy, color);
            rl.DrawLine(cx, cy - 12, cx, cy - 4, color);
            rl.DrawLine(cx, cy + 4, cx, cy + 12, color);
            card(center - 260, height - 176, 520, 52);
            self.centeredText(if (ready) "Subject in frame - press P to record" else "Photo camera", center, height - 161, .body, color);
        }
        if (simulation.externally_clocked) {
            card(center - 260, 156, 520, 92);
            self.centeredText("Agent control", center, 172, .value, ink);
            self.centeredText("Paused between actions", center, 212, .body, secondary);
        }
        if (self.debug) {
            card(24, 156, 348, 180);
            self.text(rl.TextFormat("%d FPS", rl.GetFPS()), 44, 172, .value, ink);
            self.text(rl.TextFormat("%d / 64 chunks", @as(c_int, @intCast(chunks))), 176, 177, .body, secondary);
            self.text(rl.TextFormat("X %.1f   Y %.1f   Z %.1f", @as(f64, simulation.drone.position.x), @as(f64, simulation.drone.position.y), @as(f64, simulation.drone.position.z)), 44, 216, .body, ink);
            self.text(rl.TextFormat("Seed %llu", @as(c_ulonglong, simulation.seed)), 44, 252, .body, secondary);
            self.text(rl.TextFormat("Tick %llu", @as(c_ulonglong, simulation.tick)), 44, 288, .body, secondary);
        }
        if (simulation.gameOver() or rl.GetTime() < self.notice_until) {
            const notice_y: f32 = if (simulation.externally_clocked) 268 else 156;
            card(center - 260, notice_y, 520, 100);
            self.centeredText(if (simulation.gameOver()) "Study complete" else if (self.identified) "Species recorded" else "Subject not ready", center, notice_y + 16, .value, accent);
            self.centeredText(if (simulation.gameOver()) "All 3 species documented" else if (self.identified) "Find the next animal" else "Move closer and center the animal", center, notice_y + 60, .body, ink);
        }
    }
};

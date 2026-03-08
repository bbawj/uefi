pub const Vec2 = struct {
    x: i64,
    y: i64,

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return Vec2{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return Vec2{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn mult(self: Vec2, s: f64) Vec2 {
        return Vec2{ .x = @intFromFloat(@as(f64, @floatFromInt(self.x)) * s), .y = @intFromFloat(@as(f64, @floatFromInt(self.y)) * s) };
    }
};

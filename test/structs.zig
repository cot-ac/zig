const Point = struct {
    x: i32,
    y: i32,
};

pub fn main() u8 {
    const p: Point = Point{ .x = 20, .y = 22 };
    return @intCast(p.x + p.y);
}

const Rect = struct {
    width: i32,
    height: i32,
};

fn area(r: Rect) i32 {
    return r.width * r.height;
}

pub fn main() u8 {
    const r: Rect = Rect{ .width = 6, .height = 7 };
    return @intCast(area(r));
}

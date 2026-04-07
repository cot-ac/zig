const Color = enum {
    Red,
    Green,
    Blue,
};

fn colorVal(c: Color) i32 {
    return @as(i32, c);
}

fn main() i32 {
    var b: Color = .Blue;
    return colorVal(b);
}

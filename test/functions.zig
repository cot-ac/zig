fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn main() u8 {
    return @intCast(add(20, 22));
}

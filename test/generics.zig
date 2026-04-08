fn add(comptime T: type, a: T, b: T) T {
    return a + b;
}

pub fn main() u8 {
    const result = add(i32, 20, 22);
    return @intCast(result);
}

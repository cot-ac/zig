pub fn main() u8 {
    const small: i32 = 42;
    const big: i64 = @as(i64, small);
    const back: i32 = @as(i32, big);
    return @intCast(back);
}

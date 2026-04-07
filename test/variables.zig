pub fn main() u8 {
    const x: i32 = 10;
    var y: i32 = 20;
    y += 12;
    return @intCast(x + y);
}

pub fn main() u8 {
    var x: i32 = 10;
    if (x > 5) {
        x = 42;
    } else {
        x = 0;
    }
    return @intCast(x);
}

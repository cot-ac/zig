pub fn main() u8 {
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < 7) {
        sum += 6;
        i += 1;
    }
    return @intCast(sum);
}

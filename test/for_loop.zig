pub fn main() u8 {
    var sum: i32 = 0;
    for (0..6) |_| {
        sum += 7;
    }
    return @intCast(sum);
}

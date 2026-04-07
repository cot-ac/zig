pub fn main() u8 {
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < 100) {
        i += 1;
        if (i == 3) {
            continue;
        }
        if (i > 9) {
            break;
        }
        sum += i;
    }
    return @intCast(sum);
}

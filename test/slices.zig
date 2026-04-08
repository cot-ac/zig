fn sumSlice(s: []const i32) i32 {
    var total: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        total += s[i];
        i += 1;
    }
    return total;
}

pub fn main() u8 {
    var arr = [_]i32{ 10, 20, 12 };
    const result = sumSlice(&arr);
    return @intCast(result);
}

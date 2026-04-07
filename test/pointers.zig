fn addViaPtr(p: *i32, val: i32) void {
    p.* = p.* + val;
}

pub fn main() u8 {
    var x: i32 = 20;
    addViaPtr(&x, 22);
    return @intCast(x);
}

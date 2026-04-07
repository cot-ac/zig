fn getValue(x: ?i32) i32 {
    return x orelse 0;
}

pub fn main() u8 {
    const a: ?i32 = 42;
    const b: ?i32 = null;
    const r1 = getValue(a);
    const r2 = getValue(b);
    return @intCast(r1 - r2);
}

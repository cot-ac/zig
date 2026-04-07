const MyError = error{BadValue};

fn mayFail(x: i32) MyError!i32 {
    if (x < 0) {
        return error.BadValue;
    }
    return x;
}

fn safe(x: i32) i32 {
    return mayFail(x) catch 0;
}

pub fn main() u8 {
    const a = safe(42);
    const b = safe(-1);
    return @intCast(a - b);
}

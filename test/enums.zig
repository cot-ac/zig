const Color = enum { Red, Green, Blue };

fn colorValue(c: Color) i32 {
    switch (c) {
        .Red => {
            return 10;
        },
        .Green => {
            return 20;
        },
        .Blue => {
            return 42;
        },
    }
    return 0;
}

pub fn main() u8 {
    const c: Color = .Blue;
    const result = colorValue(c);
    return @intCast(result);
}

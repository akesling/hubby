fn majority(count: usize, total: usize) -> bool {
    count > total / 2
}
fn guarded_division(x: u8, y: u8) -> bool {
    y != 0 && x / y > 1
}
fn increment(x: u8) -> u8 {
    let mut value = x;
    value = value + 1;
    assert!(value > x);
    value
}
fn choose(x: u64, y: u64) -> u64 {
    if x > y {
        x
    } else {
        y
    }
}
fn call_order(x: u8, y: u8) -> bool {
    let ignored = increment(x);
    guarded_division(ignored, y)
}
fn arithmetic(x: u8, y: u8) -> u8 {
    let a = x.wrapping_add(y);
    let b = a.saturating_sub(x);
    b.wrapping_sub(y).saturating_add(x).max(y).min(a)
}
fn add(x: u8, y: u8) -> u8 {
    x + y
}
fn sub(x: u8, y: u8) -> u8 {
    x - y
}
fn mul(x: u8, y: u8) -> u8 {
    x * y
}
fn div(x: u8, y: u8) -> u8 {
    x / y
}
fn rem(x: u8, y: u8) -> u8 {
    x % y
}
fn assertion(x: u8, y: u8) -> u8 {
    assert!(x <= y);
    x
}
fn nested_calls(x: u8, y: u8) -> u8 {
    let a = y;
    let y = x;
    sub(add(a, 1), sub(y, 1))
}
fn short_circuit(x: u8, y: u8) -> bool {
    x == 0 || !(y / x != 1)
}
fn bits(x: u8, y: u8) -> u8 {
    let mut a = x.wrapping_mul(y);
    a ^= (x & y) | (x ^ y);
    a
}
fn shl(x: u8, y: u8) -> u8 {
    x << y
}
fn shr(x: u8, y: u8) -> u8 {
    x >> y
}
fn mix(x: u64, y: u64) -> u64 {
    let a = x.wrapping_add(y);
    let mut b = (a ^ (a >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    b = (b ^ (b >> 27)).wrapping_mul(0x94d049bb133111eb);
    b ^= b >> 31;
    b
}

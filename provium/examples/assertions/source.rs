fn increment(x: u8) -> u8 {
    assert!(x < 255);
    x + 1
}
fn guarded_division(x: u8, y: u8) -> bool {
    y != 0 && x / y > 1
}

const std = @import("std");
const SpinLock = @This();

locked: std.atomic.Value(u8),
pub fn init() SpinLock {
    return .{ .locked = std.atomic.Value(u8).init(0) };
}
pub fn lock(self: *SpinLock) void {
    while (true) {
        _ = (self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic)) orelse return;
        std.atomic.spinLoopHint();
    }
}
pub fn unlock(self: *SpinLock) void {
    _ = self.locked.store(0, .release);
}

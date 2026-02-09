const std = @import("std");
const SysLock = @This();
const spins: u8 = 4;
const pausePerSpin: u8 = 30;
syslock: std.Thread.Mutex,
pub fn init() SysLock {
    return .{
        .syslock = .{},
    };
}
pub fn lock(self: *SysLock) void {
    var i: u8 = 0;
    while (i < spins) : (i += 1) {
        if (!self.syslock.tryLock()) {
            for (0..pausePerSpin) |_| {
                std.atomic.spinLoopHint();
            }
        } else {
            return; // Acquired the Lock
        }
    }
    self.syslock.lock();
}
pub fn unlock(self: *SysLock) void {
    self.syslock.unlock();
}

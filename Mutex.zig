const std = @import("std");
const Allocator = std.mem.Allocator;
const Runtime = @import("runtime.zig");
const Mutex = @This();
const WaitGroup = @import("WaitGroup.zig");
const ErrQTable = @import("QTable.zig").Err;
const Sleep = @import("Sleep.zig").Sleep;
const testing = std.testing;
// locked means, that somebody has acquired this Lock
const muLocked: u64 = 1;
inline fn waiters(val: u64) u64 {
    return val >> 32;
}
inline fn addWaiter(old: u64) u64 {
    return (old & muLocked) | ((waiters(old) + 1) << 32);
}
inline fn reduceWaiter(old: u64) u64 {
    return (old & muLocked) | ((waiters(old) - 1) << 32);
}

val: std.atomic.Value(u64),
sema: u32,

pub fn init(allocator: Allocator) !*Mutex {
    const m = try allocator.create(Mutex);
    m.val = std.atomic.Value(u64).init(0);
    m.sema = 0;
    return m;
}
pub fn deinit(self: *Mutex, allocator: Allocator) void {
    defer allocator.destroy(self);
}

pub fn lock(self: *Mutex) void {
    if (self.tryFastPath()) {
        return; // Lock Acquired
    }
    self.lockSlow();
}

fn lockSlow(self: *Mutex) void {
    var iter: u32 = 0;
    var current = self.val.raw; // It's safe to read from the underlying variable as CAS would ensure correct state transition.
    var awoken = false;
    while (true) {
        // either, this is a new GoRoutine, trying to get Mutex
        // or a woken GoRoutine.
        if (iter < Runtime.spinLockIterations and current & muLocked == muLocked) {
            // This busy loops checks if there is possibility to acquire the lock
            // without adding to the waitQueue
            std.atomic.spinLoopHint();
            current = self.val.raw;
            iter += 1;
            continue;
        }
        // Either spin exhausted or lock is unlocked.
        if (current & muLocked == 0) {
            // unlocked

            const next = current | muLocked;
            current = self.val.cmpxchgWeak(current, next, .acquire, .monotonic) orelse {
                // Time to return
                return;
            };
        }
        // we reached here: spin exhausted or somebody else took the lock
        // Lets add a waiter count
        const new = addWaiter(current);
        current = self.val.cmpxchgWeak(current, new, .acquire, .monotonic) orelse {
            Runtime.waitGo(&self.sema, !awoken) catch {
                unreachable;
            };
            // Awaken GoR continues from here.

            // This flag is important, so that if a newly awaken
            // GoRoutine fails to acquire the Lock, it will be
            // added to the front of the queue.
            awoken = true;
            iter = 0;
            current = self.val.raw;
            continue;
        };
    }
}

fn tryFastPath(self: *Mutex) bool {
    _ = self.val.cmpxchgWeak(0, 1, .acquire, .monotonic) orelse return true;
    return false;
}
pub fn unlock(self: *Mutex) void {
    // Reseting the Mutex
    const old = self.val.fetchSub(1, .monotonic);
    if (old == muLocked) { // Unlock fast path, there was no waiter
        return;
    }

    self.unlockSlow(old - 1); // There are some waiters
}

fn unlockSlow(self: *Mutex, current: u64) void {
    var old = current;
    while (waiters(old) > 0 and old & (muLocked) == 0) { // if we have a waiter, lock is unlocked
        const next = reduceWaiter(old);
        old = self.val.cmpxchgWeak(old, next, .acquire, .monotonic) orelse {
            Runtime.freeOne(&self.sema) catch {
                unreachable;
            };
            return;
        };
        // We are here, it means somebody has acquired the lock already.
        // No benefit of waking up any GoRoutine.
    }
}

test "smoke_test" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testFn, .{runt});
}

test "ping_pong_test" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testPingPong, .{runt});
}
test "hammer_test" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testHammer, .{runt});
}

fn testFn(runt: *Runtime.Runtime) !void {
    const f = struct {
        fn run(m: *Mutex, wg: *WaitGroup, counter: *u32) void {
            defer wg.Done();
            for (0..10000) |_| {
                m.lock();
                counter.* = 1 + counter.*;
                m.unlock();
            }
        }
    };
    var m = try Mutex.init(runt.allocator);
    var w = try WaitGroup.init(runt.allocator);
    const cnter = try runt.allocator.create(u32);
    defer runt.allocator.destroy(cnter);
    defer m.deinit(runt.allocator);
    defer w.deinit(runt.allocator);
    cnter.* = 0;

    w.Add(10);
    for (0..10) |_| {
        runt.Go(f.run, .{ m, w, cnter });
    }
    w.Wait();
    try testing.expect(cnter.* == 100_000);
}
fn testPingPong(runt: *Runtime.Runtime) !void {
    const f = struct {
        fn run(m: *Mutex, wg: *WaitGroup, isPing: bool, counter: *u32) void {
            defer wg.Done();
            m.lock();
            Sleep(std.time.ns_per_ms * 100);
            if (isPing) {
                counter.* = counter.* | 1;
            } else {
                counter.* = counter.* | 2;
            }
            m.unlock();
        }
    };
    var m = try Mutex.init(runt.allocator);
    var w = try WaitGroup.init(runt.allocator);
    const cnter = try runt.allocator.create(u32);
    defer runt.allocator.destroy(cnter);
    defer m.deinit(runt.allocator);
    defer w.deinit(runt.allocator);
    cnter.* = 0;

    w.Add(2);
    runt.Go(f.run, .{ m, w, true, cnter });
    runt.Go(f.run, .{ m, w, false, cnter });
    w.Wait();
    try testing.expect(cnter.* == 3);
}
fn testHammer(runt: *Runtime.Runtime) !void {
    const f = struct {
        fn run(m: *Mutex, wg: *WaitGroup, n: *u32, isSnail: bool) void {
            defer wg.Done();
            m.lock();
            if (isSnail) {
                Sleep(std.time.ns_per_ms * 1000);
            }
            n.* = n.* + 1;
            m.unlock();
        }
    };
    var m = try Mutex.init(runt.allocator);
    var w = try WaitGroup.init(runt.allocator);
    defer m.deinit(runt.allocator);
    defer w.deinit(runt.allocator);
    const count: u32 = 10001;
    w.Add(count);
    var n: u32 = 0;
    runt.Go(f.run, .{ m, w, &n, true });
    for (1..count) |_| {
        runt.Go(f.run, .{ m, w, &n, false });
    }
    w.Wait();
    try testing.expect(n == count);
}

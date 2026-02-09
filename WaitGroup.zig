const std = @import("std");
const Allocator = std.mem.Allocator;
const Runtime = @import("runtime.zig");
const WaitGroup = @This();
const Sleep = @import("Sleep.zig").Sleep;
const time = std.time;
const testing = std.testing;
// Higer 32 bits stores number of GoRoutines added
// Lower 32 bits stores number of Waiters
val: std.atomic.Value(u64),
sema: u32, // for waiter counters

pub fn init(allocator: Allocator) !*WaitGroup {
    const wg = try allocator.create(WaitGroup);
    wg.val = std.atomic.Value(u64).init(0);
    wg.sema = 0;
    return wg;
}
pub fn deinit(self: *WaitGroup, allocator: Allocator) void {
    defer allocator.destroy(self);
}

pub fn Wait(self: *WaitGroup) void {
    while (true) {
        const state = self.val.load(.monotonic);
        if (state == 0) {
            return; // Nothing to wait for
        }
        // Time to add the waiter
        if (self.val.cmpxchgWeak(state, state + 1, .acquire, .monotonic) == null) {
            // We have to put this GoR into the wait Queue
            // and suspends it, until the conunter becomes 0.
            Runtime.waitGo(&self.sema, true) catch {
                unreachable;
            };

            return;
        }
    }
}

pub fn Add(self: *WaitGroup, n: u32) void {
    var x: u64 = @intCast(n);
    x <<= 32;
    _ = self.val.fetchAdd(x, .monotonic);
}

pub fn Done(self: *WaitGroup) void {
    // TODO: Justify monotonic
    const x: u64 = 1 << 32;
    const prev = self.val.fetchSub(x, .monotonic);
    const latest = prev - x;
    const prevCounter: u64 = prev >> 32;
    if (prevCounter == 0) {
        @panic("waitgroup was already empty");
    } else if (prevCounter == 1) {
        // This was one last GoRoutine
        const waiter = prev & ((1 << 32) - 1);
        if (waiter > 0) {
            // Time to free all the waiters
            if (self.val.cmpxchgWeak(latest, 0, .acquire, .monotonic)) |_| {
                // Counter changed while processing,
                // Time to panic as per Go runtime
                // Convention:
                // i.e. New GoRoutines should be added only after all the waiter was released
                // when counter became 0 last time.
                @panic("waitgroup state changed, while releasing waiters");
            }
            Runtime.freeGo(&self.sema) catch {
                unreachable;
            };
        }
    }
}

test "smoke_test" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testFn, .{runt});
}
test "test_fanout" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testFanoutFn, .{runt});
}

fn testFanoutFn(runt: *Runtime.Runtime) !void {
    const w = try WaitGroup.init(runt.allocator);
    defer w.deinit(runt.allocator);
    const CT = std.atomic.Value(u16);
    const counter = try runt.allocator.create(CT);
    defer runt.allocator.destroy(counter);
    counter.* = CT.init(0);
    const f = struct {
        fn run(wg: *WaitGroup, c: *CT) void {
            defer wg.Done();
            Sleep(50 * time.ns_per_ms);
            _ = c.fetchAdd(1, .seq_cst);
        }
    };
    w.Add(1000);
    for (0..1000) |_| {
        runt.Go(f.run, .{ w, counter });
    }
    w.Wait();
    try testing.expect(counter.load(.monotonic) == 1000);
}

fn testFn(runt: *Runtime.Runtime) !void {
    const w = try WaitGroup.init(runt.allocator);
    defer w.deinit(runt.allocator);
    const done = try runt.allocator.create(bool);
    defer runt.allocator.destroy(done);
    done.* = false;
    const f = struct {
        fn run(wg: *WaitGroup, d: *bool) void {
            defer wg.Done();
            Sleep(50 * time.ns_per_ms);
            d.* = true;
        }
    };
    w.Add(1);
    runt.Go(f.run, .{ w, done });
    w.Wait();
    try testing.expect(done.*);
}

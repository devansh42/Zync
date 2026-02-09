const GoRoutine = Runtime.GoRoutine;
const Runtime = @import("runtime.zig");
const Asm = @import("Asm.zig");
const std = @import("std");
const testing = std.testing;
const time = std.time;
fn addToSleepingList(dur: i128) *GoRoutine {
    const runt = Runtime.globalRuntime.?;
    const g = Runtime.currentM.curG;
    var n = runt.allocator.create(Runtime.SGNode) catch {
        unreachable;
    };

    g.state = .Waiting;
    n.go = g;
    const p = Runtime.currentM.p;
    p.addSlept(n, dur);
    return g;
}

pub fn Sleep(dur: i128) void {
    if (dur <= 0) {
        return;
    }
    const g = addToSleepingList(dur);
    const done = Asm.saveStateBeforeSwitching(&g.lss); // Saving registers
    if (done == Asm.Done) {
        return; // Just Woke up
    }
    g.lss.sp = asm volatile (
        \\ mov x9, sp
        : [_] "={x9}" (-> usize),
        :
        : .{ .memory = true });
    Runtime.gopark(g);
}

test "smoke_test" {
    const allocator = testing.allocator;
    var runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testSmoke, .{runt});
    std.Thread.sleep(time.ns_per_s);
}

test "concurrent_sleep" {
    const allocator = testing.allocator;
    var runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testConcurrentSleep, .{runt});
    std.Thread.sleep(time.ns_per_s);
}

// test "sleep_order" {
//     const allocator = testing.allocator;
//     var runt = try Runtime.Runtime.init(allocator);
//     defer runt.deinit();
//     runt.Main(testSleepOrder, .{runt});
//     std.Thread.sleep(time.ns_per_s);
// }

fn testSleepOrder(runt: *Runtime.Runtime) !void {
    const ar = [_]i128{ 100, 200, 500, 600, 400 };
    const res = try runt.allocator.alloc(i128, 5);
    defer runt.allocator.free(res);
    const num = try runt.allocator.create(u8);
    defer runt.allocator.destroy(num);
    num.* = 0;
    const f = struct {
        fn run(du: i128, n: *u8, re: []i128) void {
            Sleep(time.ns_per_ms * du);
            re[n.*] = du;
            n.* += 1;
        }
    };
    for (0..ar.len) |i| {
        runt.Go(f.run, .{ ar[i], num, res });
    }
    Sleep(time.ns_per_ms * 800); // Taking margin of 100ms for context switching
    const expected = [_]i128{ 100, 200, 400, 500, 600 };
    try testing.expectEqualSlices(i128, &expected, res);
}

fn testConcurrentSleep(runt: *Runtime.Runtime) !void {
    const num = try runt.allocator.create(u8);
    num.* = 0;
    defer runt.allocator.destroy(num);
    const f1 = struct {
        fn run(n: *u8) void {
            Sleep(time.ns_per_ms * 200);
            n.* |= 1;
        }
    };
    const f2 = struct {
        fn run(n: *u8) void {
            Sleep(time.ns_per_ms * 100);
            n.* |= 2;
        }
    };
    runt.Go(f1.run, .{num});
    runt.Go(f2.run, .{num});
    Sleep(time.ns_per_ms * 350);
    // After 350ms, both of the above GoRoutines should be executed
    // We are taking a margin of 50 ms, for  context switch logic
    try testing.expect(num.* == 3);
}

fn testSmoke(_: *Runtime.Runtime) !void {
    const start = time.nanoTimestamp();
    Sleep(200 * time.ns_per_ms);
    const timeTaken = time.nanoTimestamp() - start;
    try testing.expect(timeTaken >= 200 * time.ns_per_ms);
}

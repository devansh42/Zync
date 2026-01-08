const runtime = @import("runtime.zig");
const std = @import("std");
const SpinLock = @import("SpinLock.zig");
const Thread = std.Thread;
const print = std.debug.print;

const Runtime = runtime.Runtime;

test "smoke_test" {
    var runt = try Runtime.init(std.testing.allocator_instance.allocator());
    defer runt.deinit();
    runt.Main(testFn, .{runt});
    Thread.sleep(5_000_000_000); // Blocking the main thread for 60 seconds
}

fn testFn(runt: *Runtime) !void {
    print("\nHi, It's Main Func", .{});
    print("\nHi, It's Main Func1", .{});
    runt.Go(factorialFn, .{runt});
    print("\nHi, It's Main Func2", .{});
    print("\nHi, It's Main Func3", .{});
    print("\nHi, It's Main Func3", .{});
    print("\nHi, It's Main Func4", .{});
}

fn factorialFn(runt: *Runtime) !void {
    print("\nFactorial: What a wonderful day", .{});
    const lock = try runt.allocator.create(SpinLock);
    lock.* = SpinLock.init();
    for (0..1000) |i| {
        const str = "\nIt's a new day, It's new dawn";
        runt.Go(printMsg, .{ str, i, lock });
    }
}

fn printMsg(msg: []const u8, i: usize, lock: *SpinLock) void {
    lock.lock();
    defer lock.unlock();
    const x = std.heap.page_allocator;
    // const buf = x.alloc(u8, 1) catch {
    //     unreachable;
    // };
    const num = std.fmt.allocPrint(x, ": {}", .{i}) catch {
        unreachable;
    };
    defer x.free(num);
    var stderr = std.fs.File.stderr();
    // const wr = stderr.writer(buf);
    // var w = wr.interface;

    _ = stderr.writeAll(msg) catch {
        unreachable;
    };
    _ = stderr.writeAll(num) catch {
        unreachable;
    };
}

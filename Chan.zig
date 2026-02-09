const std = @import("std");
const Runtime = @import("runtime.zig");
const Allocator = std.mem.Allocator;
const SysLock = @import("SysLock.zig");
const WaitGroup = @import("WaitGroup.zig");
const Sleep = @import("Sleep.zig").Sleep;
const Asm = @import("Asm.zig");
const testing = std.testing;

pub fn Chan(T: type) type {
    const Tuple = struct { go: *Runtime.GoRoutine, addr: *T };
    const Node = struct { node: std.DoublyLinkedList.Node, tuple: Tuple };
    return struct {
        lock: SysLock,
        sendq: std.DoublyLinkedList,
        recvq: std.DoublyLinkedList,
        senders: u32,
        recvs: u32,
        closed: bool,
        allocator: Allocator,
        const Self = @This();
        pub fn init(allocator: Allocator) !*Self {
            var x = try allocator.create(Self);
            x.lock = SysLock.init();
            x.sendq = .{};
            x.recvq = .{};
            x.recvs = 0;
            x.senders = 0;
            x.closed = false;
            x.allocator = allocator;
            return x;
        }
        pub fn deinit(self: *Self, allocator: Allocator) void {
            defer allocator.destroy(self);
            self.cleanQ(&self.sendq);
            self.cleanQ(&self.recvq);
        }
        pub fn close(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.closed) {
                unreachable;
            }
            self.closed = true;
            self.releaseAll(&self.recvq) catch {
                unreachable;
            };
            self.releaseAll(&self.sendq) catch {
                unreachable;
            };
        }
        pub fn send(self: *Self, val: T) void {
            self._send(val) catch {
                unreachable;
            };
        }
        pub fn recv(self: *Self, ptr: *T) bool {
            return self._recv(ptr) catch {
                unreachable;
            };
        }
        fn _send(self: *Self, val: T) !void {
            var woke = false;
            while (true) {
                self.lock.lock();
                if (self.closed) {
                    self.lock.unlock();
                    @panic("send on closed channel");
                } else if (woke) {
                    self.lock.unlock();
                    return; // It's definite that if the GoRoutine is awaken on a open channel that means, data has been delivered.
                } else if (self.recvs > 0) {
                    // fast path
                    const t = self.removeG(&self.recvq) catch |err| {
                        self.lock.unlock();
                        return err;
                    };
                    Runtime.addRunable(t.go, self.allocator) catch |err| {
                        self.lock.unlock();
                        return err;
                    };
                    self.recvs -= 1;
                    t.addr.* = val; // Direct HandOff
                    self.lock.unlock();
                    return;
                } else {
                    // No recievers
                    // Time to sleep
                    const g = self.addG(&self.sendq, @constCast(&val)) catch |err| {
                        self.lock.unlock();
                        return err;
                    };
                    self.senders += 1;
                    self.lock.unlock();
                    Runtime.sleepGo(g);
                    // Resumes here
                    woke = true;
                }
            }
        }

        fn _recv(self: *Self, ptr: *T) !bool {
            var woke = false;
            while (true) {
                self.lock.lock();
                if (self.closed) {
                    ptr.* = undefined; // Equalivant to zero value
                    self.lock.unlock();
                    return false;
                } else if (woke) {
                    self.lock.unlock();
                    return true; // It's definite that if a GoRoutine is awken on open channel, it already has the data set.
                } else if (self.senders > 0) {
                    // fast recv
                    const t = self.removeG(&self.sendq) catch |err| {
                        self.lock.unlock();
                        return err;
                    };

                    Runtime.addRunable(t.go, self.allocator) catch |err| {
                        self.lock.unlock();
                        return err;
                    };
                    self.senders -= 1;
                    ptr.* = t.addr.*; // Direct Handoff
                    self.lock.unlock();
                    return true;
                } else {
                    // slow recv
                    // Sleep
                    const g = self.addG(&self.recvq, ptr) catch |err| {
                        self.lock.unlock();
                        return err;
                    };
                    self.recvs += 1;
                    self.lock.unlock();
                    Runtime.sleepGo(g);
                    // Resumes here
                    woke = true;
                }
            }
        }
        fn removeG(self: *Self, q: *std.DoublyLinkedList) !Tuple {
            const node = q.popFirst().?;
            const parent = @as(*Node, @fieldParentPtr("node", node));
            defer self.allocator.destroy(parent);
            return parent.tuple;
        }
        fn addG(self: *Self, q: *std.DoublyLinkedList, addr: *T) !*Runtime.GoRoutine {
            const node = try self.allocator.create(Node);
            node.tuple.go = Runtime.currentM.curG;
            node.tuple.addr = addr;
            q.append(&node.node);
            return node.tuple.go;
        }
        fn releaseAll(self: *Self, q: *std.DoublyLinkedList) !void {
            while (true) {
                const node = (q.popFirst()) orelse {
                    return;
                };
                const parent = @as(*Node, @fieldParentPtr("node", node));
                defer self.allocator.destroy(parent);
                try Runtime.addRunable(parent.tuple.go, self.allocator);
            }
        }
        fn cleanQ(self: *Self, q: *std.DoublyLinkedList) void {
            while (true) {
                const node = (q.popFirst()) orelse {
                    return;
                };
                const parent = @as(*Node, @fieldParentPtr("node", node));
                self.allocator.destroy(parent);
            }
        }
    };
}
test "ping_pong_test" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testPingPong, .{runt});
}
test "fan_in_test" {
    const allocator = std.testing.allocator;
    const runt = try Runtime.Runtime.init(allocator);
    defer runt.deinit();
    runt.Main(testFanIn, .{runt});
}
// test "fifo_close" {
//     const allocator = std.testing.allocator;
//     const runt = try Runtime.Runtime.init(allocator);
//     defer runt.deinit();
//     runt.Main(testFifoClose, .{runt});
// }

fn testPingPong(runt: *Runtime.Runtime) !void {
    const ch = try Chan(u32).init(runt.allocator);
    defer ch.deinit(runt.allocator);
    defer ch.close();
    const f = struct {
        fn run(cha: *Chan(u32)) void {
            cha.send(42);
        }
    };
    runt.Go(f.run, .{ch});
    var x: u32 = 0;
    _ = ch.recv(&x);
    try testing.expect(x == 42);
}
fn testFanIn(runt: *Runtime.Runtime) !void {
    const ch = try Chan(u32).init(runt.allocator);
    defer ch.deinit(runt.allocator);
    var wg = try WaitGroup.init(runt.allocator);
    defer wg.deinit(runt.allocator);
    const f = struct {
        fn run(cha: *Chan(u32), w: *WaitGroup) void {
            defer w.Done();
            cha.send(1);
        }
        fn cls(cha: *Chan(u32), w: *WaitGroup) void {
            w.Wait();
            cha.close();
        }
    };
    const count = 1_000;
    wg.Add(count);
    for (0..count) |_| {
        runt.Go(f.run, .{ ch, wg });
    }
    runt.Go(f.cls, .{ ch, wg });
    var x: u32 = undefined;
    var sum: u32 = 0;
    while (ch.recv(&x)) {
        sum += x;
    }

    try testing.expect(sum == count);
}
fn testFifoClose(runt: *Runtime.Runtime) !void {
    const ch = try Chan(u32).init(runt.allocator);
    defer ch.deinit(runt.allocator);
    var wg = try WaitGroup.init(runt.allocator);
    defer wg.deinit(runt.allocator);
    const T = std.atomic.Value(u8);
    const i = try runt.allocator.create(T);
    i.* = std.atomic.Value(u8).init(0);
    defer runt.allocator.destroy(i);
    const ans = try runt.allocator.alloc(u32, 5);
    defer runt.allocator.free(ans);
    const f = struct {
        fn run(cha: *Chan(u32), timeMS: u32, in: *T, a: []u32, w: *WaitGroup) void {
            defer w.Done();
            var x: u32 = undefined;
            Sleep(timeMS * std.time.ns_per_ms);
            if (!cha.recv(&x)) {
                const y = in.fetchAdd(1, .monotonic);
                a[y] = timeMS;
            }
        }
    };
    const ar = [_]u32{ 50, 100, 150, 200, 250 };
    wg.Add(5);
    for (ar) |v| {
        runt.Go(f.run, .{ ch, v, i, ans, wg });
    }
    Sleep(300 * std.time.ns_per_ms);
    ch.close();
    wg.Wait();
    try testing.expectEqualSlices(u32, &ar, ans);
}

const std = @import("std");
const SpinLock = @import("SpinLock.zig");
const Allocator = std.mem.Allocator;
pub const Err = error{ Empty, NotFound };
pub fn QTable(comptime T: type) type {
    const Node = struct {
        node: std.DoublyLinkedList.Node,
        val: T,
    };
    return struct {
        hash: std.hash_map.AutoHashMapUnmanaged(usize, *std.DoublyLinkedList),
        lock: *SpinLock,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !*QTable(T) {
            const wq = try allocator.create(QTable(T));
            wq.allocator = allocator;
            wq.hash = .empty;
            return wq;
        }
        pub fn deinit(self: *QTable(T)) void {
            defer self.allocator.destroy(self);
            self.cleanupVals();
            self.hash.clearAndFree(self.allocator);
            self.hash.deinit(self.allocator);
        }
        fn cleanupVals(self: *QTable(T)) void {
            var iter = self.hash.keyIterator();
            while (true) {
                const key = iter.next() orelse return;
                if (self.hash.get(key.*)) |list| {
                    var ll = list;
                    while (true) {
                        if (ll.pop()) |node| {
                            const parent = @as(*Node, @fieldParentPtr("node", node));
                            self.allocator.destroy(parent);
                        } else {
                            break;
                        }
                    }
                    self.allocator.destroy(list);
                }
            }
        }
        pub fn append(self: *QTable(T), key: usize, val: T) !void {
            try self.put(key, val, true);
        }
        pub fn prepend(self: *QTable(T), key: usize, val: T) !void {
            try self.put(key, val, false);
        }

        fn put(self: *QTable(T), key: usize, val: T, _append: bool) !void {
            var res: *std.DoublyLinkedList = undefined;
            var n = try self.allocator.create(Node);
            n.val = val;
            if (self.hash.get(key)) |l| {
                res = l;
            } else {
                res = try self.allocator.create(std.DoublyLinkedList);
                res.* = .{};
                try self.hash.put(self.allocator, key, res);
            }
            if (_append) {
                res.append(&n.node);
            } else {
                res.prepend(&n.node);
            }
        }

        pub fn next(self: QTable(T), key: usize) !T {
            var val = self.hash.get(key) orelse return Err.NotFound;
            const node = val.popFirst() orelse return Err.Empty;
            const parent = @as(*Node, @fieldParentPtr("node", node));
            defer self.allocator.destroy(parent);
            return parent.val;
        }
        pub fn drain(self: QTable(T), key: usize, allocator: Allocator) ![]T {
            var val = self.hash.get(key) orelse return Err.NotFound;
            const len = val.len(); // Considering to the list to be small
            if (len == 0) {
                return Err.Empty;
            }
            const list = try allocator.alloc(T, len);
            for (0..len) |i| {
                const node = val.popFirst() orelse return list;
                const parent = @as(*Node, @fieldParentPtr("node", node));
                defer self.allocator.destroy(parent);
                list[i] = parent.val;
            }
            return list;
        }
    };
}

test "smoke_test" {
    const x = QTable(u8);
    const wq = try x.init(
        std.testing.allocator,
    );
    defer wq.deinit();

    try wq.append(1, 10);
    const val = try wq.next(1);
    try std.testing.expect(val == 10);
    _ = wq.next(2) catch |err| {
        try std.testing.expect(err == Err.NotFound);
    };
    try wq.append(1, 20);
    try wq.append(1, 30);
    try wq.prepend(1, 40);
    const ar = try wq.drain(1, std.testing.allocator);
    const exp = [_]u8{ 40, 20, 30 };
    try std.testing.expectEqualSlices(u8, &exp, ar);
    defer std.testing.allocator.free(ar);
}

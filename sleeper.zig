const std = @import("std");
pub const Treap = std.Treap(i128, earlyTime);
const Allocator = std.mem.Allocator;
const SpinLock = @import("SpinLock.zig");
const sleeper = @This();
treap: Treap,

pub fn init() sleeper {
    return .{ .treap = .{} };
}

pub const Empty: Treap.Node = .{ .key = 0, .parent = null, .priority = 0, .children = [_]?*Treap.Node{ null, null } };

pub fn add(self: *sleeper, dur: i128, node: *Treap.Node) void {
    var now = std.time.nanoTimestamp();
    now += dur;
    while (true) {
        var entry: Treap.Entry = self.treap.getEntryFor(now);
        if (entry.node) |_| {
            now += 1;
            // Increasing the duration to find a uniq slot
            // as nano second precision is not usefull.
        } else {
            entry.set(node);
            return;
        }
    }
}

pub fn nextIfPast(self: *sleeper) ?*Treap.Node {
    const n = self.treap.getMin() orelse return null;
    if (std.time.nanoTimestamp() >= n.key) {
        var e = self.treap.getEntryForExisting(n);
        e.set(null);
        return n;
    }
    return null;
}

fn earlyTime(a: i128, b: i128) std.math.Order {
    return std.math.order(a, b);
}

test "smoke_test" {
    var slp = sleeper.init();
    const dn = Empty;
    const n = struct { node: Treap.Node = dn, key: i128 };
    var onsec: n = .{ .key = std.time.ns_per_s, .node = dn };
    var onsec2: n = .{ .key = std.time.ns_per_s, .node = dn };
    var ms500n: n = .{ .key = std.time.ns_per_ms * 500, .node = dn };
    var ms400n: n = .{ .key = std.time.ns_per_ms * 400, .node = dn };
    var ms300n: n = .{ .key = std.time.ns_per_ms * 300, .node = dn };
    var ms200n: n = .{ .key = std.time.ns_per_ms * 200, .node = dn };

    slp.add(onsec.key, @constCast(&onsec.node));
    slp.add(onsec2.key, @constCast(&onsec2.node));
    slp.add(ms500n.key, @constCast(&ms500n.node));
    slp.add(ms300n.key, @constCast(&ms300n.node));
    slp.add(ms400n.key, @constCast(&ms400n.node));
    slp.add(ms200n.key, @constCast(&ms200n.node));
    const e = std.testing.expect;
    try e(slp.nextIfPast() == null);
    sleep(ms200n.key);
    try e(slp.nextIfPast().? == &ms200n.node);
    sleep(ms200n.key);
    try e(slp.nextIfPast().? == &ms300n.node);
    try e(slp.nextIfPast().? == &ms400n.node);
    sleep(ms200n.key);
    try e(slp.nextIfPast().? == &ms500n.node);
    sleep(ms500n.key);
    // Multiple node with same key
    try e(slp.nextIfPast().? == &onsec.node);
    try e(slp.nextIfPast().? == &onsec2.node);
}

fn sleep(n: i128) void {
    const t: u64 = @intCast(n);
    std.Thread.sleep(t);
}

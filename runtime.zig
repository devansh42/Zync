const std = @import("std");
const SpinLock = @import("SpinLock.zig");
const Asm = @import("Asm.zig");
const QTable = @import("QTable.zig").QTable;
const sleeper = @import("sleeper.zig");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// Thread Local Variables
pub threadlocal var currentGoRoutine: ?*GoRoutine = null;
pub var globalRuntime: ?*Runtime = null;

//
const lockPoolSize: usize = 251; // As This is a prime number
const initalStackSize: usize = 32 * 1024;
const unlocked: u32 = 0;
const locked: u32 = 1;
const contended: u32 = locked << 1;
pub const spinLockIterations = 10;
const print = std.debug.print;
const assert = std.debug.assert;
const mask: usize = 15;
const GoMaxProc = 4;
const GoState = enum {
    Ready,
    Running,
    Blocked,
    Slept,
    Done,
};
const Err = error{NotFound};
pub const GoRoutine = struct {
    sp: usize = 0, // Stack Pointer
    pc: usize = 0, // Program Counter
    m: *M,
    stack: []u8,
    lss: Asm.RoutineRegisters,
    g0state: Asm.RoutineRegisters,
    isMain: bool = false,
    state: GoState,
};

const GNode = struct {
    go: *GoRoutine,
    node: std.DoublyLinkedList.Node = .{},
};
pub const SGNode = struct {
    go: *GoRoutine,
    node: sleeper.Treap.Node = sleeper.Empty,
};
const M = struct {
    stack_base: usize = 0,
    p: *P, // Acquired P
    lock: SpinLock,
    runt: *Runtime,
    curG: *GoRoutine,
    fn init(allocater: Allocator) !*M {
        var m = try allocater.create(M);
        m.lock = SpinLock.init();
        return m;
    }
};

const P = struct {
    queue: std.DoublyLinkedList = .{}, // List of Ready GoRoutines
    timerHeap: sleeper,
    lock: SpinLock,
    size: usize,
    fn init(allocator: Allocator) !*P {
        var p = try allocator.create(P);
        p.lock = SpinLock.init();
        p.size = 0;
        p.timerHeap.treap.root = null;
        return p;
    }

    pub fn addSlept(self: *P, n: *SGNode, dur: i128) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.timerHeap.add(dur, &n.node);
    }
    fn nextSlept(self: *P) ?*sleeper.Treap.Node {
        self.lock.lock();
        defer self.lock.unlock();
        return self.timerHeap.nextIfPast();
    }
    fn add(self: *P, go: *GNode) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.size += 1;
        self.queue.append(&go.node);
    }

    fn next(self: *P) ?*std.DoublyLinkedList.Node {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.size == 0) {
            return null;
        }
        self.size -= 1;
        return self.queue.popFirst();
    }
};
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    m: []*M,
    p: []*P,
    ths: []std.Thread,
    waitTable: *QTable(*GoRoutine),
    spinLockPool: []SpinLock,
    pub fn init(allocator: Allocator) !*Runtime {
        const self = try allocator.create(Runtime);
        self.allocator = allocator;
        self.waitTable = try QTable(*GoRoutine).init(allocator);
        try self.initLockPool();
        self.m = try allocator.alloc(*M, GoMaxProc);
        self.p = try allocator.alloc(*P, GoMaxProc);
        self.ths = try allocator.alloc(std.Thread, GoMaxProc);
        for (0..GoMaxProc) |i| {
            const p = try P.init(allocator);
            const m = try M.init(allocator);
            p.queue.first = null;
            p.queue.last = null;
            p.timerHeap.treap.root = null;
            m.lock = SpinLock.init(); // Being allocated on stack
            self.m[i] = m;
            self.p[i] = p;
            m.p = p; // Keeping 1:1 static mapping in the beginning
            m.runt = @constCast(self);
            self.ths[i] = try Thread.spawn(.{}, g0, .{m});
            self.ths[i].detach();
        }
        globalRuntime = self;
        return self;
    }

    fn initLockPool(self: *Runtime) !void {
        self.spinLockPool = try self.allocator.alloc(SpinLock, lockPoolSize);
        for (0..lockPoolSize) |i| {
            self.spinLockPool[i] = SpinLock.init();
        }
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.allocator;
        defer allocator.destroy(self);
        for (0..GoMaxProc) |i| {
            allocator.destroy(self.p[i]);
            allocator.destroy(self.m[i]);
        }
        allocator.free(self.ths);
        allocator.free(self.p);
        allocator.free(self.m);
        allocator.free(self.spinLockPool);
        self.waitTable.deinit();
    }

    // Main, takes place of Main function
    // This function is also managed by runtime
    // Main should be called on the Main thread, as it blocks the main thread
    // until the execution is complete
    pub fn Main(self: *Runtime, comptime func: anytype, args: anytype) void {
        const i = randomIndex(self.m.len);
        newproc(self.m[i], self.allocator, true, func, args) catch {
            unreachable;
        };
    }
    pub fn Go(self: *Runtime, comptime func: anytype, args: anytype) void {
        // New GoRoutine will go to a randomly picked machine's processor
        const i = randomIndex(self.m.len);
        newproc(self.m[i], self.allocator, false, func, args) catch {
            unreachable;
        };
    }
};

fn randomIndex(len: usize) usize {
    const seed: u64 = @intCast(std.time.microTimestamp());
    var r = std.Random.Xoroshiro128.init(seed);
    return r.random().uintLessThan(usize, len);
}

fn createStack(allocator: Allocator, go: *GoRoutine) !void {
    const stack = try allocator.alloc(u8, initalStackSize);
    go.stack = stack;
    // We are aligning the memory
    // in 16 bytes blocks
    // to speed up CPU Cacheline reads
    go.sp = (@intFromPtr(stack.ptr) & ~mask) + stack.len;
}

fn initializeRegs(go: *GoRoutine, funcInfo: usize) void {
    go.lss = .{
        .sp = go.sp,
        .x19 = go.sp, // Bundle Start
        .x20 = funcInfo, // Link Register
        .x30 = @intFromPtr(&Asm.genFn),
        .x28 = @intFromPtr(go),
    };
}

fn copyArgsOnStack(go: *GoRoutine, comptime func: anytype, args: anytype) usize {
    const Bundle = struct { args: @TypeOf(args) };
    const Wrapper = struct {
        fn invoker(bun: *Bundle) callconv(.c) void {
            const fncType = @TypeOf(func);
            const tInfo = @typeInfo(fncType);
            const returnT = switch (tInfo) {
                .@"fn" => tInfo.@"fn".return_type.?,
                .pointer => |p| switch (@typeInfo(p.child)) {
                    .@"fn" => |f| f.return_type.?,
                    else => @compileError("func should be function or function pointer"),
                },
                else => @compileError("func should be function or function poiner"),
            };
            const returnInfo = @typeInfo(returnT);
            switch (returnInfo) {
                .error_union => {
                    @call(.auto, func, bun.args) catch {
                        unreachable;
                    };
                },
                else => {
                    @call(.auto, func, bun.args);
                },
            }
            goexit();
        }
    };
    const bun: Bundle = .{ .args = args };
    const prevsp = go.sp;
    const size: usize = @sizeOf(Bundle);
    const shift = (prevsp - size) & ~mask;
    // Copying bundle on the local stack
    const startI = shift - @intFromPtr(go.stack.ptr);
    @memcpy(go.stack[startI .. startI + size], std.mem.asBytes(&bun));
    go.sp = shift;
    return @intFromPtr(&Wrapper.invoker);
}

fn newproc(m: *M, allocator: Allocator, isMain: bool, comptime func: anytype, args: anytype) !void {
    // Start of goRoutine
    // Allocating memory for goRoutines
    // Ideally, We should use a resource pool for this
    // GoRuntime keeps these stacks elastic
    const go = try allocator.create(GoRoutine);
    const node = try allocator.create(GNode);
    node.go = go;
    go.m = m;
    go.isMain = isMain;
    go.state = .Ready;
    try createStack(allocator, go);
    const funcInfo = copyArgsOnStack(go, func, args);
    initializeRegs(go, funcInfo);
    m.p.add(node); // GoRoutine added to the current local run queue
}

fn g0(m: *M) void {
    m.stack_base = asm volatile (
        \\ mov sp, sp
        : [ret] "={sp}" (-> usize),
        :
        : .{ .memory = true });
    schedule(m);
}

fn destory(allocator: Allocator, g: *GoRoutine) void {
    allocator.free(g.stack);
    allocator.destroy(g);
}

// schedule always runs on thread stack
fn schedule(m: *M) callconv(.c) void {
    var attempts: u8 = 3;
    while (true) {
        if (m.p.nextSlept()) |node| {
            const sgnode = @as(*SGNode, @fieldParentPtr("node", node));
            const work = sgnode.go;
            m.runt.allocator.destroy(sgnode); // No Longer required.
            work.state = .Ready;
            run(work, m);
            continue;
        } else if (m.p.next()) |node| {
            const gnode = @as(*GNode, @fieldParentPtr("node", node));
            const work = gnode.go;
            m.runt.allocator.destroy(gnode); // No Longer required.
            run(work, m);
            continue;
        }
        attempts -= 1;
        if (attempts < 1) {
            Thread.sleep(10_000_000); // Sleeping for 10ms
            attempts = 3;
            continue;
        }
    }
}

fn run(work: *GoRoutine, m: *M) void {
    switch (work.state) {
        .Done => destory(m.runt.allocator, work),
        .Ready => {
            work.state = .Running;
            m.curG = work;
            currentGoRoutine = work;
            Asm.restoreStateAndSwitch(&work.lss);
        },
        else => {},
    }
}

//goexit is called, when goRoutine gets done with it stuff.
fn goexit() void {
    // Save Go Routine State: Currently no use case in current context
    // Cleanup goRoutine
    // Reset Stack

    const addr = Asm.savg();
    const g = @as(*GoRoutine, @ptrFromInt(addr));
    const stack_base: usize = g.m.stack_base;
    const m = g.m;
    clenaupG(g.m.runt, g);
    Asm.resetThreadStack(stack_base, @intFromPtr(&schedule), @intFromPtr(m));
}

fn clenaupG(runt: *Runtime, g: *GoRoutine) void {
    g.state = .Done;
    const gnode = runt.allocator.create(GNode) catch {
        unreachable;
    };
    gnode.go = g;
    g.m.p.add(gnode);
}

// gopark does the context switch
// and resets stack to the g0 stack pointer
pub fn gopark(g: *GoRoutine) void {
    const m = g.m;
    Asm.resetThreadStack(m.stack_base, @intFromPtr(&schedule), @intFromPtr(m));
}

fn addToBlockList(addr: usize) !*GoRoutine {
    // addr is 16 byte align address,
    // we are ignoring 4 least significant bits
    // as it would always be 0
    const hashKey = addr >> 4;
    const runt = globalRuntime.?;
    var lock = runt.spinLockPool[hashKey % lockPoolSize];
    const g = currentGoRoutine.?;
    g.state = .Blocked;
    lock.lock();
    errdefer lock.unlock(); // Just incase, an-error occurs while adding to the waitTable
    try runt.waitTable.put(addr, g);
    lock.unlock();
    return g;
}

fn freeBlockList(addr: usize) !void {
    // addr is 16 byte align address,
    // we are ignoring 4 least significant bits
    // as it would always be 0
    const hashKey = addr >> 4;
    const runt = globalRuntime.?;
    var lock = runt.spinLockPool[hashKey % lockPoolSize];
    lock.lock();
    errdefer lock.unlock(); // Just in-case, an error occurs while removing from waitTable
    const gs = try runt.waitTable.drain(addr, runt.allocator);
    lock.unlock();
    defer runt.allocator.free(gs);
    try addRunableList(gs, runt.allocator);
}

fn addRunableList(ar: []*GoRoutine, allocator: Allocator) !void {
    for (0..ar.len) |i| {
        ar[i].state = .Ready;
        const n = try allocator.create(GNode);
        n.go = ar[i];
        ar[i].m.p.add(n);
    }
    print("\nGoRs added to the respective Processors", .{});
}

// waitGo adds the current GoR into
// the wait list
// And then does the context switch
// This runs in the GoR's stack until gopark calls resetThreadStack
pub fn waitGo(addr: usize) !void {
    const g = try addToBlockList(addr);
    // Now, we should just save the state of this GoRoutine
    Asm.saveStateBeforeSwitching(&g.lss);
    // now, g.lss.x30 is
    // pointing to the next instruction
    // We will save the stack pointer using inline assembly
    // so that when this goRoutine becomes alive again it can continue
    // from this stack position

    if (g.state == .Running) {
        print("\nWaiter became running again", .{});
        // This means, GoR just became alive
        // Assuming all registers are restored.
        // Time to resume
        return; // Returning back to the caller (i.e. x30)
    }
    // Saving current sp location in
    // to continue again with the same stack frame ones back
    g.lss.sp = asm volatile (
        \\ mov x9, sp
        : [_] "={x9}" (-> usize),
        :
        : .{ .memory = true });
    gopark(g);
}

pub fn freeGo(addr: usize) !void {
    try freeBlockList(addr);
}

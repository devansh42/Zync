const std = @import("std");
const SpinLock = @import("SpinLock.zig");
const Asm = @import("Asm.zig");
const QTable = @import("QTable.zig").QTable;
const ErrQTable = @import("QTable.zig").Err;
const sleeper = @import("sleeper.zig");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const atomicUsize = std.atomic.Value(usize);
// Thread Local Variables
pub threadlocal var currentM: *M = undefined;
pub var globalRuntime: ?*Runtime = null;

//
const lockPoolSize: usize = 251; // As This is a prime number
const initalStackSize: usize = 64 * 1024;
const unlocked: u32 = 0;
const locked: u32 = 1;
const contended: u32 = locked << 1;
pub const spinLockIterations = 10;
const assert = std.debug.assert;
const mask: usize = 15;
pub const GoMaxProc = 8;
const GoState = enum(u8) {
    Ready = 1,
    Running = 2,
    Waiting = 3,
    Done = 4,
};
const PState = enum(u8) {
    Idle = 1,
    Busy = 2,
};
const MState = enum(u8) {
    Idle = 1,
    Spinning = 2,
    Busy = 3,
};
const Err = error{NotFound};
pub const GoRoutine = struct {
    sp: usize = 0, // Stack Pointer
    pc: usize = 0, // Program Counter
    stack: []u8,
    lss: Asm.RoutineRegisters,
    isMain: bool = false,
    state: GoState,
    node: std.SinglyLinkedList.Node,
    id: u32 = 0,
};

pub const SGNode = struct {
    go: *GoRoutine,
    node: sleeper.Treap.Node = sleeper.Empty,
};
const M = struct {
    id: u32 = 0,
    lss: Asm.RoutineRegisters = .{},
    lock: SpinLock,
    runt: *Runtime,
    curG: *GoRoutine = undefined,
    p: *P = undefined, // Acquired P
    sema: std.Thread.Semaphore = .{ .permits = 0 },
    th: std.Thread = undefined,
    state: std.atomic.Value(MState) = std.atomic.Value(MState).init(.Idle),
    fn init(runt: *Runtime, id: u32) M {
        return .{
            .lock = SpinLock.init(),
            .runt = runt,
            .id = id,
        };
    }
};

fn runQlen(h: usize, t: usize) usize {
    return h -% t;
}

const P = struct {
    id: u32 = 0,
    runq: [256]*GoRoutine,
    timerHeap: sleeper,
    grq: *Grq,
    qhead: std.atomic.Value(usize),
    qtail: std.atomic.Value(usize),
    m: *M = undefined,
    state: std.atomic.Value(PState) = std.atomic.Value(PState).init(.Idle),
    nextTimeout: std.atomic.Value(i128),
    freelist: std.SinglyLinkedList,
    fn init(grq: *Grq, id: u32) P {
        return .{
            .runq = undefined,
            .grq = grq,
            .qhead = std.atomic.Value(usize).init(0),
            .qtail = std.atomic.Value(usize).init(0),
            .timerHeap = sleeper.init(),
            .freelist = .{},
            .id = id,
            .nextTimeout = std.atomic.Value(i128).init(-1),
        };
    }
    fn deinit(self: *P) void {
        while (true) {
            if (self.freelist.popFirst()) |node| {
                const g = @as(*GoRoutine, @fieldParentPtr("node", node));
                globalRuntime.?.mpool.putStack(g.stack);
                globalRuntime.?.mpool.putG(g);
            } else {
                break;
            }
        }
        std.debug.assert(self.timerHeap.len() == 0);
    }
    pub fn addSlept(self: *P, n: *SGNode, dur: i128) void {
        self.timerHeap.add(dur, &n.node);
    }
    fn nextSlept(self: *P) ?*sleeper.Treap.Node {
        return self.timerHeap.nextIfPast();
    }
    fn peekSleepTimer(self: *P) ?i128 {
        return self.timerHeap.peek();
    }
    fn free(self: *P, go: *GoRoutine) void {
        self.freelist.prepend(&go.node);
    }
    fn nextRemovable(self: *P) ?*GoRoutine {
        if (self.freelist.popFirst()) |node| {
            const g = @as(*GoRoutine, @fieldParentPtr("node", node));
            return @constCast(g);
        }
        return null;
    }
    fn add(self: *P, go: *GoRoutine) !void {
        const h = self.qhead.load(.acquire);
        const t = self.qtail.load(.acquire);
        if (runQlen(h, t) < self.runq.len) { // We need this loop for protecting against Work Stealing.
            self.runq[h % self.runq.len] = go; // Adding to the Ring Buffer
            _ = self.qhead.fetchAdd(1, .release); // moving head forward
            try self.shouldDelegate();
        } else if (runQlen(h, t) == self.runq.len) {
            try self.grq.add(go); // Full, need to add to Global Run Queue
            return;
        }
    }
    fn shouldDelegate(_: *P) !void {
        if (globalRuntime.?.spiningMCount.load(.monotonic) > 0) {
            return; // Neigbhour will eventually steal
        }
        if (@atomicLoad(u8, &globalRuntime.?.t_midle, .monotonic) > 0) {
            if (globalRuntime.?.wakem()) {
                return; // Woke up a neighbour
            }
        }
        if (globalRuntime.?.workerThCount.load(.monotonic) < GoMaxProc) {
            _ = try globalRuntime.?.startm();
            return;
        }
    }
    fn stealFromGrq(self: *P) usize {
        const l = self.runq.len / 2;
        const h = self.qhead.load(.acquire);
        const start = h % self.runq.len;
        const delta = @min(l, self.runq.len - start); // TODO: Maximise this movement
        const s = self.grq.move(self.runq[start .. start + delta]);
        if (s > 0) {
            _ = self.qhead.fetchAdd(s, .release);
            return s;
        }
        return 0;
    }
    fn heistWork(self: *P, dest: []*GoRoutine) usize {
        const h = self.qhead.load(.acquire);
        const t = self.qtail.load(.acquire);
        const s = @min(dest.len, runQlen(h, t));
        var nt = t;
        for (0..s) |i| {
            dest[i] = self.runq[nt % self.runq.len];
            nt = (nt +% 1);
        }
        if (self.qtail.cmpxchgWeak(t, nt, .acq_rel, .monotonic) == null) {
            return s;
        }
        return 0;
    }
    fn addStolen(self: *P, steals: usize) void {
        _ = self.qhead.fetchAdd(steals, .release);
    }

    fn workCount(self: *P) usize {
        const h = self.qhead.load(.acquire);
        const t = self.qtail.load(.acquire);
        return runQlen(h, t);
    }
    fn next(self: *P) ?*GoRoutine {
        const t = self.qtail.load(.acquire);
        const h = self.qhead.load(.acquire);
        if (runQlen(h, t) > 0) {
            const g = self.runq[t % self.runq.len];
            const nt = (t +% 1);
            _ = self.qtail.cmpxchgWeak(t, nt, .acq_rel, .monotonic) orelse {
                return @constCast(g);
            };
        }
        return null;
    }
};

const Sysmon = struct {
    th: std.Thread,
    runt: *Runtime,
    sema: std.Thread.Semaphore = .{ .permits = 0 },

    fn init(runt: *Runtime) Sysmon {
        return .{
            .runt = runt,
            .th = undefined,
        };
    }
    fn deinit(self: *Sysmon) void {
        self.sema.post();
        self.th.join();
    }
    fn sysmonFn(self: *Sysmon) !void {
        var backOffTimeout: u64 = 20 * std.time.ns_per_us; // 20 microseconds
        while (!self.runt.closeSignal.load(.monotonic)) {
            if (self.releaseAnyTimer()) {
                // Let's sleep for some time
                backOffTimeout = 20 * std.time.ns_per_us;
            }
            self.sema.timedWait(backOffTimeout) catch {};
            // We have to use SemaPhore only
            if (backOffTimeout < std.time.ns_per_ms * 10) {
                backOffTimeout *= 2;
            }
        }
    }
    fn releaseAnyTimer(self: *Sysmon) bool {
        const now = std.time.nanoTimestamp();
        var i = @atomicLoad(u8, &self.runt.t_pidle, .monotonic);
        while (i > 0) {
            i -= 1;
            const nextTime = self.runt.pidle[i].nextTimeout.load(.acquire);
            if (nextTime > 0 and nextTime <= now and self.runt.pidle[i].state.load(.acquire) == .Idle) {
                const justWoken = self.runt.directHandOffP(i);
                return justWoken;
            }
        }
        return false;
    }

    fn start(self: *Sysmon) !void {
        self.th = try Thread.spawn(.{}, sysmonFn, .{self});
    }
};

const Grq = struct {
    list: std.SinglyLinkedList,
    lock: SpinLock,
    size: usize,
    allocator: Allocator,
    const gnode = struct {
        node: std.SinglyLinkedList.Node,
        g: *GoRoutine,
    };
    fn init(allocator: Allocator) Grq {
        return .{
            .list = .{},
            .lock = SpinLock.init(),
            .size = 0,
            .allocator = allocator,
        };
    }
    fn deinit(self: *Grq) void {
        var count: usize = 0;
        while (true) {
            if (self.list.popFirst()) |n| {
                const ele = @as(*gnode, @fieldParentPtr("node", n));
                self.allocator.destroy(ele);
                count += 1;
            } else {
                break;
            }
        }
        std.debug.assert(count == 0);
    }
    fn add(self: *Grq, g: *GoRoutine) !void {
        self.lock.lock();
        defer self.lock.unlock();
        self.size += 1;
        var gn = try self.allocator.create(gnode);
        gn.g = g;
        self.list.prepend(&gn.node);
    }
    // dest points to calling P's stack
    fn move(self: *Grq, dest: []*GoRoutine) usize {
        self.lock.lock();
        defer self.lock.unlock();
        const l = @min(dest.len, self.size);
        if (l == 0) {
            return l;
        }
        var i: usize = 0;
        while (i < dest.len) : (i += 1) {
            const n = self.list.popFirst() orelse break;
            const ele = @as(*gnode, @fieldParentPtr("node", n));
            defer self.allocator.destroy(ele);
            dest[i] = ele.g;
        }
        self.size -= i;
        return i;
    }
};

const stackNode = struct {
    node: std.SinglyLinkedList.Node,
    stack: []u8,
};
const ResourcePool = struct {
    gmpool: std.heap.MemoryPool(GoRoutine),
    stackFreeList: std.SinglyLinkedList,
    allocator: Allocator,
    lock: Thread.Mutex,
    fn init(allocator: Allocator) ResourcePool {
        return .{
            .gmpool = std.heap.MemoryPool(GoRoutine).init(allocator),
            .stackFreeList = .{},
            .allocator = allocator,
            .lock = .{},
        };
    }
    fn getG(self: *ResourcePool) !*GoRoutine {
        return try self.gmpool.create();
    }
    fn getStack(self: *ResourcePool) ![]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.stackFreeList.popFirst()) |node| {
            const stack = @as(*stackNode, @fieldParentPtr("node", node));
            return stack.stack;
        }
        return try self.allocator.alloc(u8, initalStackSize);
    }
    fn putG(self: *ResourcePool, g: *GoRoutine) void {
        self.gmpool.destroy(g);
    }
    fn putStack(self: *ResourcePool, stack: []u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        @memset(stack, undefined);
        const node = self.allocator.create(stackNode) catch unreachable;
        node.stack = stack;
        self.stackFreeList.prepend(&node.node);
    }
    fn deinit(self: *ResourcePool) void {
        self.gmpool.deinit();
        self.lock.lock();
        defer self.lock.unlock();
        while (true) {
            if (self.stackFreeList.popFirst()) |node| {
                const stackn = @as(*stackNode, @fieldParentPtr("node", node));
                self.allocator.free(stackn.stack);
                self.allocator.destroy(stackn);
            } else {
                break;
            }
        }
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    m: []M,
    p: []P,
    pidle: []*P,
    midle: []*M,
    t_midle: u8,
    t_pidle: u8,
    rountineCounter: std.atomic.Value(u32),
    workerThCount: std.atomic.Value(u8),
    spiningMCount: std.atomic.Value(u32),
    waitTable: *QTable(*GoRoutine),
    spinLockPool: []SpinLock,
    mainSema: std.Thread.Semaphore,
    closeSignal: std.atomic.Value(bool),
    lock: SpinLock,
    grq: Grq,
    sysmon: Sysmon,
    mpool: ResourcePool,
    pub fn init(allocator: Allocator) !*Runtime {
        const self = try allocator.create(Runtime);
        self.allocator = allocator;
        self.waitTable = try QTable(*GoRoutine).init(allocator);
        try self.initLockPool();
        self.grq = Grq.init(allocator);
        self.m = try allocator.alloc(M, GoMaxProc);
        self.midle = try allocator.alloc(*M, GoMaxProc);
        self.pidle = try allocator.alloc(*P, GoMaxProc);
        self.t_pidle = GoMaxProc;
        self.t_midle = 0;
        self.p = try allocator.alloc(P, GoMaxProc);
        self.workerThCount = std.atomic.Value(u8).init(0);
        self.spiningMCount = std.atomic.Value(u32).init(0);
        self.rountineCounter = std.atomic.Value(u32).init(0);
        self.lock = SpinLock.init();
        self.sysmon = Sysmon.init(@constCast(self));
        self.mpool = ResourcePool.init(allocator);
        for (0..GoMaxProc) |i| {
            self.p[i] = P.init(&self.grq, @intCast(i));
            self.m[i] = M.init(@constCast(self), @intCast(i));
            self.pidle[i] = &self.p[i];
        }
        self.mainSema = .{ .permits = 0 };
        self.closeSignal = std.atomic.Value(bool).init(false);
        globalRuntime = self;
        try self.sysmon.start();
        return self;
    }

    fn giveupm(self: *Runtime, m: *M, timeout: i128) !void {
        // This method detaches the P
        // and blocks the thread attached to M
        self.lock.lock();
        const p_top = self.t_pidle;
        const m_top = self.t_midle;
        m.p.nextTimeout.store(timeout, .release);
        m.p.state.store(.Idle, .release);
        m.state.store(.Idle, .release);
        self.pidle[p_top] = m.p;
        m.p.m = undefined;
        m.p = undefined;

        self.midle[m_top] = m;
        self.t_midle += 1;
        self.t_pidle += 1;
        // We are unlocking lock, as semaphore is synchronised internally.
        self.lock.unlock();
        // Time to Sleep
        while (m.state.load(.acquire) == .Idle) {
            sema_wait(m);
            // The thread can wake up because of following reasons:
            // 1. Timed out
            //  It's possible that this newly woken thread is waken but there is no P available
            // 2. Sparous Wake Up
            // Nothing much we need to do here
            // 3. Waked up by wake (self.closeSignal.load(.monotonic)) {
            return;
        }
        // The thread would wake up here
    }
    fn closed(self: *Runtime) bool {
        return self.closeSignal.load(.monotonic);
    }
    fn sema_wait(m: *M) void {
        m.sema.wait();
    }
    // wakem wakes up a blocked thread
    // it returns true, it could wake someone
    // and returns false, if it couldn't find one to wake up
    fn wakem(self: *Runtime) bool {
        self.lock.lock();
        var m_top = self.t_midle;
        var p_top = self.t_pidle;
        if (m_top == 0 or p_top == 0) {
            // We don't have an idle M or P
            self.lock.unlock();
            return false;
        }
        m_top -= 1;
        p_top -= 1;
        self.midle[m_top].p = self.pidle[p_top];
        self.pidle[p_top].m = self.midle[m_top];
        const m = self.midle[m_top];
        self.t_midle -= 1;
        self.t_pidle -= 1;
        m.p.state.store(.Busy, .release);
        m.state.store(.Busy, .release);
        // We are unlocking lock, as semaphore is synchronised internally.
        self.lock.unlock();
        // Time to wake up
        m.sema.post();
        return true;
    }

    fn directHandOffP(self: *Runtime, pIndex: u8) bool {
        self.lock.lock();
        if (self.pidle[pIndex].state.raw != .Idle) {
            self.lock.unlock();
            return false;
        }
        var m_top = self.t_midle;
        if (m_top == 0) {
            // We don't have an idle M
            self.lock.unlock();
            return false;
        }
        self.t_midle -= 1;
        self.t_pidle -= 1;
        m_top = self.t_midle;
        self.midle[m_top].p = self.pidle[pIndex];
        self.pidle[pIndex].m = self.midle[m_top];
        const m = self.midle[m_top];
        m.p.state.store(.Busy, .release);
        m.state.store(.Busy, .release);
        // Swap the p_top with pIndex
        if (self.t_pidle > 0) {
            const p_top = self.t_pidle;
            const temp = self.pidle[p_top];
            self.pidle[p_top] = self.pidle[pIndex];
            self.pidle[pIndex] = temp;
        }
        // We are unlocking lock, as semaphore is synchronised internally.
        self.lock.unlock();
        // Time to wake up
        m.sema.post();
        return true;
    }

    //  startm starts a new thread and attaches and idle P to it.
    // returns true, if it were able to start the thread.
    fn startm(self: *Runtime) !bool {
        var wh: u8 = undefined;
        while (true) {
            wh = self.workerThCount.raw;
            if (wh == GoMaxProc) {
                return false;
            }
            _ = self.workerThCount.cmpxchgWeak(wh, wh + 1, .acquire, .monotonic) orelse {
                break;
            };
        }
        self.lock.lock();
        self.t_pidle -= 1;
        const top_p = self.t_pidle;
        var m: *M = @constCast(&self.m[wh]);
        self.pidle[top_p].m = m;
        m.p = self.pidle[top_p];
        m.state.store(.Busy, .release);
        m.p.state.store(.Busy, .release);
        self.lock.unlock();
        m.th = try Thread.spawn(.{}, schedule, .{@constCast(&self.m[wh])});
        return true;
    }

    fn initLockPool(self: *Runtime) !void {
        self.spinLockPool = try self.allocator.alloc(SpinLock, lockPoolSize);
        for (0..lockPoolSize) |i| {
            self.spinLockPool[i] = SpinLock.init();
        }
    }

    pub fn deinit(self: *Runtime) void {
        self.closeSignal.store(true, .monotonic);
        for (0..self.workerThCount.load(.monotonic)) |i| {
            self.m[i].sema.post();
            self.m[i].th.join(); // Waiting for threads to complete
        }
        self.sysmon.deinit();
        for (0..self.p.len) |i| {
            self.p[i].deinit();
        }
        const allocator = self.allocator;
        defer allocator.destroy(self);
        allocator.free(self.midle);
        allocator.free(self.pidle);
        allocator.free(self.p);
        allocator.free(self.m);
        allocator.free(self.spinLockPool);
        self.grq.deinit();
        self.waitTable.deinit();
        self.mpool.deinit();
    }

    // Main, takes place of Main function
    // This function is also managed by runtime
    // Main should be called on the Main thread, as it blocks the main thread
    // until the execution is complete
    pub fn Main(self: *Runtime, comptime func: anytype, args: anytype) void {
        newproc(self.pidle[self.t_pidle - 1], self.allocator, true, func, args) catch {
            unreachable;
        };
        // Starts M0
        _ = self.startm() catch {
            unreachable;
        };
        self.mainSema.wait();
    }
    pub fn Go(self: *Runtime, comptime func: anytype, args: anytype) void {
        // New GoRoutine will go to current GoRoutine's P
        newproc(currentM.p, self.allocator, false, func, args) catch {
            unreachable;
        };
    }
};

fn randomShuffle(ar: []usize) void {
    const seed: u64 = @intCast(std.time.microTimestamp());
    var r = std.Random.Xoroshiro128.init(seed);
    r.random().shuffle(usize, ar);
}

fn createStack(runt: *Runtime, go: *GoRoutine) !void {
    const stack = try runt.mpool.getStack();
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

fn newproc(p: *P, _: Allocator, isMain: bool, comptime func: anytype, args: anytype) !void {
    // Start of goRoutine
    // Allocating memory for goRoutines
    // Ideally, We should use a resource pool for this
    // GoRuntime keeps these stacks elastic
    const runt = globalRuntime.?;
    const go = try runt.mpool.getG();
    // std.debug.print("\nGoRoutine Addr: {*}", .{go});
    go.isMain = isMain;
    go.state = .Ready;
    go.id = runt.rountineCounter.fetchAdd(1, .monotonic);
    try createStack(runt, go);
    const funcInfo = copyArgsOnStack(go, func, args);
    initializeRegs(go, funcInfo);
    try p.add(go); // GoRoutine added to the current local run queue
}

fn g0(m: *M) void {
    schedule(m);
}

fn destroy(_: Allocator, g: *GoRoutine) void {
    const runt = globalRuntime.?;
    if (g.isMain) {
        defer runt.mainSema.post();
    }
    runt.mpool.putStack(g.stack);
    // std.debug.print("\nDestroyed: {*}", .{g});
    runt.mpool.putG(g);
}

const maxScheduleIteration: usize = 1000;
// schedule always runs on thread stack
fn schedule(m: *M) callconv(.c) void {
    currentM = m;
    var ar: [GoMaxProc]usize = undefined;
    for (0..ar.len) |i| {
        ar[i] = i;
    }
    var waitedOnSpin = false;
    while (!globalRuntime.?.closeSignal.load(.monotonic)) {
        if (m.p.nextSlept()) |node| {
            const sgnode = @as(*SGNode, @fieldParentPtr("node", node));
            const work = sgnode.go;
            globalRuntime.?.allocator.destroy(sgnode); // No Longer required.
            work.state = .Ready;
            m.p.add(work) catch {
                unreachable;
            };
        } else if (m.p.nextRemovable()) |work| {
            run(work, m);
        } else if (m.p.next()) |work| {
            run(work, m);
        } else if (m.p.stealFromGrq() > 0) {
            m.state.store(.Busy, .release);
        } else if (stealFromNeighbours(&ar, m.p, globalRuntime.?.p) > 0) {
            m.state.store(.Busy, .release);
            // Steal work from others
        } else if (waitedOnSpin) {
            // Time to sleep
            waitedOnSpin = false;
            const timeout = anyDependableTimer(m);
            if (timeout == 0) {
                continue;
            }
            globalRuntime.?.giveupm(m, timeout) catch {
                unreachable;
            };
            // Will resume here
        } else {
            _ = globalRuntime.?.spiningMCount.fetchAdd(1, .monotonic);
            m.state.store(.Spinning, .release);
            spinWait();
            waitedOnSpin = true;
            _ = globalRuntime.?.spiningMCount.fetchSub(1, .monotonic);
        }
    }
}
fn anyDependableTimer(m: *M) i128 {
    const n = m.p.peekSleepTimer() orelse return -1;
    const now = std.time.nanoTimestamp();
    if (n <= now or n <= now + std.time.ns_per_ms * 2) {
        return 0;
    }
    return n;
}

fn spinWait() void {
    for (0..maxScheduleIteration) |_| {
        std.atomic.spinLoopHint();
    }
}

fn stealFromNeighbours(ar: []usize, curP: *P, ps: []P) usize {
    randomShuffle(ar);
    for (0..ar.len) |i| {
        if (curP == &ps[i] or ps[i].state.load(.acquire) != .Busy) {
            continue;
        }
        var wrCount = ps[i].workCount();
        if (wrCount == 0) {
            continue;
        }
        // The neighbour has something to steal
        wrCount /= 2;
        if (wrCount == 0) {
            wrCount = 1;
        }
        const start = curP.qhead.load(.acquire) % curP.runq.len;
        const delta = @min(wrCount, curP.runq.len - start);
        const steals = ps[i].heistWork(curP.runq[start .. start + delta]);
        if (steals > 0) {
            // for (start..start + steals) |j| {
            // std.debug.print("\n Stolen: {*}, s:{}, st:{}, i:{}", .{ curP.runq[j], steals, start, j });
            // }
            // Steal was successul
            curP.addStolen(steals);
            return steals;
        }
    }
    return 0;
}

fn run(work: *GoRoutine, m: *M) void {
    switch (work.state) {
        .Done => destroy(globalRuntime.?.allocator, work),
        .Ready => {
            m.state.store(.Busy, .release);
            work.state = .Running;
            m.curG = work;
            m.lss.sp = asm volatile (
                \\ mov x9, sp
                : [_] "={x9}" (-> usize),
                :
                : .{ .memory = true });
            const done = Asm.saveStateBeforeSwitching(&m.lss); // Save scheduler state
            // Scheduler will resume from here.
            if (done == Asm.Running) {
                // We need this check to ensure that we don't switch to this
                // GoR when scheduler returns to this statement
                // as work.state won't be Running in that case
                Asm.restoreStateAndSwitch(&work.lss);
            }
        },
        //  work = 0x0200000100079550
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
    // const stack_base: usize = g.m.stack_base;

    clenaupG(g);
    gopark(g);
    // Asm.resetThreadStack(stack_base, @intFromPtr(&schedule), @intFromPtr(m));
}

fn clenaupG(g: *GoRoutine) void {
    g.state = .Done;
    currentM.p.free(g);
}

// gopark does the context switch
// and resets stack to the g0 stack pointer
pub fn gopark(_: *GoRoutine) callconv(.c) void {
    Asm.restoreStateAndSwitch(&currentM.lss);
}

fn addToBlockList(_addr: *u32, fifo: bool) !*GoRoutine {
    const addr = @intFromPtr(_addr);
    const runt = globalRuntime.?;
    const g = currentM.curG;
    if (fifo) {
        try runt.waitTable.append(addr, g);
    } else {
        try runt.waitTable.prepend(addr, g);
    }
    return g;
}

fn freeBlockList(addr: usize, multiple: bool) !void {
    const runt = globalRuntime.?;
    if (multiple) {
        const gs = try runt.waitTable.drain(addr, runt.allocator);
        defer runt.allocator.free(gs);
        try addRunableList(gs, runt.allocator);
    } else {
        const g = try runt.waitTable.next(addr);
        try addRunable(g, runt.allocator);
    }
}

fn getLock(addr: usize) *SpinLock {
    // addr is 16 byte align address,
    // we are ignoring 4 least significant bits
    // as it would always be 0
    const hashKey = addr >> 4;
    const runt = globalRuntime.?;
    return &runt.spinLockPool[hashKey % lockPoolSize];
}

fn addRunableList(ar: []*GoRoutine, allocator: Allocator) !void {
    for (0..ar.len) |i| {
        try addRunable(ar[i], allocator);
    }
}

pub fn addRunable(g: *GoRoutine, _: Allocator) !void {
    g.state = .Ready;
    try currentM.p.add(g);
}

fn shouldSleep(sema: *u32) bool {
    if (sema.* > 0) {
        sema.* = sema.* - 1;
        return false;
    }
    return true;
}

fn incSema(sema: *u32) void {
    sema.* = 1 + sema.*;
}

// waitGo adds the current GoR into
// the wait list
// And then does the context switch
// This runs in the GoR's stack until gopark calls resetThreadStack
pub fn waitGo(_addr: *u32, fifo: bool) !void {
    const addr = @intFromPtr(_addr);
    var lock = getLock(addr);
    lock.lock();
    if (!shouldSleep(_addr)) {
        lock.unlock();
        return;
    }
    const g = addToBlockList(_addr, fifo) catch |err| {
        lock.unlock();
        return err;
    };
    lock.unlock();
    sleepGo(g);
}

pub fn sleepGo(g: *GoRoutine) void {
    g.state = .Waiting;
    // Now, we should just save the state of this GoRoutine
    const done = Asm.saveStateBeforeSwitching(&g.lss);
    // now, g.lss.x30 is
    // pointing to the next instruction
    // We will save the stack pointer using inline assembly
    // so that when this goRoutine becomes alive again it can continue
    // from this stack position

    if (done == Asm.Done) {
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

pub fn freeGo(_addr: *u32) !void {
    try syncFreeBlockList(_addr, true);
}

pub fn freeOne(_addr: *u32) !void {
    try syncFreeBlockList(_addr, false);
}

// syncFreeBlockList is just the sync version of freeBlockList
fn syncFreeBlockList(_addr: *u32, mul: bool) !void {
    const addr = @intFromPtr(_addr);
    var lock = getLock(addr);
    lock.lock();
    defer lock.unlock();

    freeBlockList(addr, mul) catch |err| {
        switch (err) {
            ErrQTable.Empty => incSema(_addr),
            ErrQTable.NotFound => incSema(_addr),
            else => return err,
        }
    };
}

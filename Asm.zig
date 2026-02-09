pub const Done: usize = 1;
pub const Running: usize = 0;
pub const RoutineRegisters = extern struct {
    sp: u64 = 0, // Stack Pointer
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    x29: u64 = 0, // Frame Pointers, should  be set to 0
    x30: u64 = 0,
};

// gogo does the context switching between two goRoutines
pub fn gogo(oldState: *RoutineRegisters, newState: *RoutineRegisters) void {
    asm volatile (
    // Now, as we doing a context switch, we need to take care of the current registers
    // So that we can switch back to this exact moment in future.
    // x9 is the destination register and sp is the stack pointer (x9 <- sp)
        \\ mov x9, sp 
        // now we saving the value inside x9 register (i.e. current stack pointer)
        // which is currentState. #0 points to currentState.sp
        \\ str x9, [%[old], #0]  
        \\ stp x19, x20, [%[old], #8]
        \\ stp x21, x22, [%[old], #24]
        \\ stp x23, x24, [%[old], #40]
        \\ stp x25, x26, [%[old], #56]
        \\ stp x27, x28, [%[old], #72]
        // Saving frame pointer and link register
        \\ stp x29, x30, [%[old], #88]

        // Time to load the new state
        \\ ldp x29, x30, [%[new], #88]
        \\ ldp x27, x28, [%[new], #72]
        \\ ldp x25, x26, [%[new], #56]
        \\ ldp x23, x24, [%[new], #40]
        \\ ldp x21, x22, [%[new], #24]
        \\ ldp x19, x20, [%[new], #8]

        // Lets overwrite the stack pointer
        \\ ldr x9, [%[new], #0]
        \\ mov sp, x9
        // jump to the link register
        \\ ret
        : // No Output
        : [old] "{x0}" (oldState),
          [new] "{x1}" (newState),
        : .{ .memory = true });
}

// savg, saves the goRoutine's state before the next context switch
pub fn savg() usize {
    return asm volatile (
    // Preserve x24 register
        \\ str x24, [sp, #-8]
        // Copy Stack Pointer
        \\ mov x24, sp
        // Save Stack Pointer
        \\ str x24, [x28, #0]
        // Copy Program Counter
        \\ adr x24, . 
        // The above value of PC contains the address for following instruction,
        // While loading this goRoutine back we will continue from the following instruction only
        // which is completely safe.

        // Save Program Counter
        \\ str x24, [x28, #8]
        // Rollback x24 register previous value
        \\ ldr x24, [sp, #-8]
        : [ret] "={x28}" (-> usize),
        :
        : .{ .memory = true });
}

// genFn calls the actual user function
pub fn genFn() void {
    asm volatile (
    // x19 have the user function arguments.
        \\ mov x0, x19
        // x20 have the address of the function being called.
        \\ blr x20
        : // No Output
        :: .{ .memory = true });
}

// resetThreadStack resets the stack pointer to g0 stack
// First Arg: (x0) is the base position for g0 stack
//
// Second Arg: (x1) is the address of the function being called after reseting the sp.
// This is going to schedule function (which actually schedules GoRoutine on the thread)
//
// Third Arg: (x2) is the argument for the function pointed by x1
pub fn resetThreadStack(_: usize, _: usize, _: usize) callconv(.c) void {
    asm volatile (
        \\ mov sp, x0
        \\ mov x30, x1
        \\ mov x0, x2
        \\ ret
        ::: .{ .memory = true });
}

// saveStateBeforeSwitching saves state of the
// GoR after adding it to block list
// Note: It doesn't save the Stack Pointer
// This should be called from the GoR about to block.
pub fn saveStateBeforeSwitching(_: *RoutineRegisters) callconv(.c) usize {
    // x0 points to state location for goRoutine
    asm volatile (
        \\ stp x19, x20, [x0, #8]
        \\ stp x21, x22, [x0, #24]
        \\ stp x23, x24, [x0, #40]
        \\ stp x25, x26, [x0, #56]
        \\ stp x27, x28, [x0, #72]
        // Saving frame pointer and link register
        \\ stp x29, x30, [x0, #88]
        \\ mov x0, #0
        ::: .{ .memory = true });
    return Running;
}

// restoreStateAndSwitch restores the GoR's register
// This should be called from g0
pub fn restoreStateAndSwitch(_: *RoutineRegisters) callconv(.c) void {
    asm volatile (
        \\ ldr x9, [x0, #0] 
        \\ mov sp, x9
        \\ ldp x19, x20, [x0, #8] 
        \\ ldp x21, x22, [x0, #24] 
        \\ ldp x23, x24, [x0, #40] 
        \\ ldp x25, x26, [x0, #56] 
        \\ ldp x27, x28, [x0, #72] 
        \\ ldp x29, x30, [x0, #88] 
        \\ mov x0 , #1
        \\ ret
    );
}

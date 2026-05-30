const println = @import("utils.zig").println;
pub const panic = struct {
    pub fn call(message: []const u8, _: ?usize) noreturn {
        println("#########################", .{});
        println("KPanic: {s}", .{message});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn sentinelMismatch(a: anytype, b: anytype) noreturn {
        println("#########################", .{});
        println("KPanic: sentinel mismatch: {x} - {x}", .{a, b});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn unwrapError(e: anyerror) noreturn {
        println("#########################", .{});
        println("KPanic: unwrap error: {?}", .{e});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn outOfBounds(a: usize, b: usize) noreturn {
        println("#########################", .{});
        println("KPanic: OOB: {d} - {d}", .{a, b});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn startGreaterThanEnd(a: usize, b: usize) noreturn {
        println("#########################", .{});
        println("KPanic: start greater than end: {d}..{d}!", .{a, b});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn inactiveUnionField(a: anytype, b: anytype) noreturn {
        println("#########################", .{});
        println("KPanic: inactive union field: {?} - {?}!", .{a, b});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn sliceCastLenRemainder(v: usize) noreturn {
        println("#########################", .{});
        println("KPanic: slice cast remainder: {d}", .{v});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn reachedUnreachable() noreturn {
        println("#########################", .{});
        println("KPanic: reached unreachable!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn unwrapNull() noreturn {
        println("#########################", .{});
        println("KPanic: unwrap on null!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn castToNull() noreturn {
        println("#########################", .{});
        println("KPanic: cast to null!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn incorrectAlignment() noreturn {
        println("#########################", .{});
        println("KPanic: incorrect alignment!!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn invalidErrorCode() noreturn {
        println("#########################", .{});
        println("KPanic: invalid error code!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn integerOutOfBounds() noreturn {
        println("#########################", .{});
        println("KPanic: integer OOB!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn integerOverflow() noreturn {
        println("#########################", .{});
        println("KPanic: integer overflow!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn shlOverflow() noreturn {
        println("#########################", .{});
        println("KPanic: << overflow!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn shrOverflow() noreturn {
        println("#########################", .{});
        println("KPanic: >> overflow!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn divideByZero() noreturn {
        println("#########################", .{});
        println("KPanic: DBZ!!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn exactDivisionRemainder() noreturn {
        println("#########################", .{});
        println("KPanic: exact division remainder!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn integerPartOutOfBounds() noreturn {
        println("#########################", .{});
        println("KPanic: integer part OOB!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn corruptSwitch() noreturn {
        println("#########################", .{});
        println("KPanic: corrupt switch!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn shiftRhsTooBig() noreturn {
        println("#########################", .{});
        println("KPanic: shift rhs too big!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn invalidEnumValue() noreturn {
        println("#########################", .{});
        println("KPanic: invalid enum value!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn forLenMismatch() noreturn {
        println("#########################", .{});
        println("KPanic: for len mismatch!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn copyLenMismatch() noreturn {
        println("#########################", .{});
        println("KPanic: copy len mismatch!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn memcpyAlias() noreturn {
        println("#########################", .{});
        println("KPanic: memcpy alias!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
    pub fn noreturnReturned() noreturn {
        println("#########################", .{});
        println("KPanic: noreturn returned!", .{});
        println("#########################", .{});
        while (true) asm volatile ("hlt");
    }
};
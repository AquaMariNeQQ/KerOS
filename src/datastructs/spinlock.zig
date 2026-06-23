const std = @import("std");

pub fn Spinlock(comptime T: type) type {
    return struct {
        comptime {
            if (!@hasDecl(T, "new")) {
                @compileError("Тип " ++ @typeName(T) ++ " должен иметь метод 'new' или 'init'");
            }
        }
        lock_value: bool = false,
        data: T = undefined,

        pub fn lock(self: *@This()) *T {
            const volatile_lock = @as(*volatile bool, &self.lock_value);
            while (@atomicRmw(bool, volatile_lock, .Xchg, true, .acquire)) {
                std.atomic.spinLoopHint();
            }
            return &self.data;
        }

        pub fn unlock(self: *@This()) void {
            const volatile_lock = @as(*volatile bool, &self.lock_value);
            @atomicStore(bool, volatile_lock, false, .release);
        }

        pub fn init(self: *volatile @This()) void {
            self.data = T.new();
        }
    };
}
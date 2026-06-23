const std = @import("std");

pub fn RwSpinlock(comptime T: type) type {
    return struct {
        state: i32 = 0,
        data: T,

        pub fn readLock(self: *@This()) *const T {
            while (true) {
                const s = @atomicLoad(i32, &self.state, .acquire);
                if (s >= 0) {
                    if (@cmpxchgWeak(i32, &self.state, s, s+1, .acquire, .monotonic) == null) {
                        return &self.data;
                    }
                }
                std.atomic.spinLoopHint();
            }
        }

        pub fn readUnlock(self: *@This()) void {
            _ = @atomicRmw(i32, &self.state, .Sub, 1, .release);
        }

        pub fn writeLock(self: *@This()) *T {
            while (@cmpxchgWeak(i32, &self.state, 0, -1, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
            return &self.data;
        }
        pub fn writeUnlock(self: *@This()) void {
            @atomicStore(i32, &self.state, 0, .release);
        }
    };
}
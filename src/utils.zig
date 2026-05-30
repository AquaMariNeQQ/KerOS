const std = @import("std");
pub const Writer = @import("std").Io.Writer;
pub fn toVirt(phys: *anyopaque) *anyopaque {
    return @ptrFromInt(@intFromPtr(phys) + PHYS_OFFSET);
}
pub fn toPhys(virt: *anyopaque) *anyopaque {
    return @ptrFromInt(@intFromPtr(virt) - PHYS_OFFSET);
}
const writeBytes = @import("arch.zig").write_bytes;
pub const PHYS_OFFSET: u64 = 0xFFFF800000000000;

fn drain(_: *Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
    var total_consumed: usize = 0;
    for (data) |slice| {
        writeBytes(slice);
        total_consumed += slice.len;
    }
    if (splat > 0) {

    }
    return total_consumed;
}
const KWriter = Writer.VTable {
    .drain = drain,
    .flush = struct {
        fn flush(w: *Writer) error{WriteFailed}!void {_=w;}
    }.flush,
    .rebase = struct {
        fn rebase(w: *Writer, preserve: usize, capacity: usize) error{WriteFailed}!void {
            _ = w; _ = preserve; _ = capacity;
        }
    }.rebase,

};

pub fn print(comptime str: []const u8, args: anytype) void {
    var writer = Writer {
        .buffer = &[_]u8{},
        .vtable = &KWriter,
    };
    writer.print(str, args) catch {};
    return;
}

pub fn println(comptime str: []const u8, args: anytype) void {
    print(str ++ "\n", args);
}
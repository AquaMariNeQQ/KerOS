const std = @import("std");
const MemoryRegion = @import("memory/memory.zig").MemoryRegion;
const MemoryRegionKind = @import("memory/memory.zig").MemoryRegionKind;


pub const BootInfo = struct {
    regions: [64]?MemoryRegion = std.mem.zeroes([64]?MemoryRegion),
    region_count: usize = 0,
    total_memory: u64 = 0,
    framebuffer: ?FramebufferInfo = null,
    platform_config_ptr: ?*anyopaque = null,
    cmdline: ?[:0]const u8 = null,
    pub fn add_region(self: *BootInfo, start: u64, end: u64, kind: MemoryRegionKind) void {
        for (&self.regions) |*slot| {
            if (slot.* == null) {
                slot.* = MemoryRegion {.start = start, .end = end, .kind = if (start < 1048576) .reserved else kind};
                self.total_memory += end - start;
                return;
            }
        }
        @panic("Regions are screwed");
    }
};

pub const FramebufferInfo = struct {
    addr: u64,
    width: u32,
    height: u32,
    bpp: u8,
    pitch: u32,
    format: PixelFormat,
};

pub const PixelFormat = enum {
    Rgb,
    Bgr,
};

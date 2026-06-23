const BootInfo = @import("../../bootsource.zig").BootInfo;
const FramebufferInfo = @import("../../bootsource.zig").FramebufferInfo;
const PixelFormat = @import("../../bootsource.zig").PixelFormat;
const std = @import("std");
const toVirt = @import("../../utils.zig").toVirt;
const Mb2InfoHeader = extern struct {
    total_size: u32,
    reserved: u32,
};

const Mb2AcpiTag = extern struct {
    typ: u32,
    size: u32,
};


const RsdpV1 = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,
};

const RsdpV2 = extern struct {
    v1: RsdpV1,
    length: u32,
    xsdt_addr: u64,
    ext_checksum: u8,
    reserved: [3]u8,
};


const Mb2MemoryMapTag = extern struct {
    typ: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
};

const Mb2MemoryArea = extern struct {
    base_addr: u64,
    length: u64,
    typ: u32,
    reserved: u32,
};

const Mb2FramebufferTag = extern struct {
    typ: u32,
    size: u32,
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    framebuffer_type: u8,
    reserved: u16,
    
    red_field_pos: u8,
    red_field_size: u8,
    green_field_pos: u8,
    green_field_size: u8,
    blue_field_pos: u8,
    blue_field_size: u8,
};

const Mb2Tag = extern struct {
    typ: u32,
    size: u32,
};

pub fn parse(ptr: *anyopaque) BootInfo {
    const hdr: *const Mb2InfoHeader = @ptrCast(@alignCast(ptr));
    var boot_info = BootInfo {};
    var offset: u32 = 8;
    const base_ptr: [*]const u8 = @ptrCast(ptr);
    while (offset < hdr.total_size) {
        const tag_ptr = base_ptr + offset;
        const tag: *const Mb2Tag = @ptrCast(@alignCast(tag_ptr));
        if (tag.size == 8 and tag.typ == 0) break;
        switch (tag.typ) {
            1 => {
                const str_ptr: [*:0]const u8 = @ptrCast(tag_ptr + 8);
                const len = std.mem.len(str_ptr);

                boot_info.cmdline = str_ptr[0..len :0];
            },
            6 => {
                const mem_tag: *const Mb2MemoryMapTag = @ptrCast(@alignCast(tag_ptr));
                const entries = (mem_tag.size - 16) / mem_tag.entry_size;
                var current_entry_ptr: *const Mb2MemoryArea = @ptrCast(@alignCast(tag_ptr + 16));
                for (0..entries) |_| {
                    const a_start = current_entry_ptr.base_addr;
                    const a_end = a_start + current_entry_ptr.length;
                    const k_start = @intFromPtr(&__phys_base);
                    const k_end = @intFromPtr(&__phys_end);
                    if (current_entry_ptr.typ == 1) {
                        const overlap_start: u64 = @max(a_start, k_start);
                        const overlap_end: u64 = @min(a_end, k_end);
                        if (overlap_start < overlap_end) {
                            if (a_start < k_start) boot_info.add_region(a_start, k_start, .usable);
                            boot_info.add_region(overlap_start, overlap_end, .kernel);
                            if (a_end > k_end) boot_info.add_region(k_end, a_end, .usable);
                        } else {
                            boot_info.add_region(a_start, a_end, .usable);
                        }
                    } else if (current_entry_ptr.typ == 5) {
                        boot_info.add_region(a_start, a_end, .bad);
                    } else if (current_entry_ptr.typ == 2 or current_entry_ptr.typ == 3 or current_entry_ptr.typ == 4) {
                        boot_info.add_region(a_start, a_end, .bootloader);
                    } else {
                        boot_info.add_region(a_start, a_end, .reserved);
                    }
                    current_entry_ptr = @ptrFromInt(@intFromPtr(current_entry_ptr) + mem_tag.entry_size);
                }
            },
            8 => {
                const fb: *const Mb2FramebufferTag = @ptrCast(@alignCast(tag_ptr));
                boot_info.framebuffer = FramebufferInfo {
                    .addr = fb.addr,
                    .width = fb.width,
                    .height = fb.height,
                    .bpp = fb.bpp,
                    .pitch = fb.pitch,
                    .format = if (fb.red_field_pos == 0) PixelFormat.Rgb else PixelFormat.Bgr,
                };
            },
            14, 15 => {
                const rsdt_ptr: *const RsdpV2 = @ptrCast(@alignCast(tag_ptr + 8));
                validate_rsdp(rsdt_ptr);
                boot_info.platform_config_ptr = toVirt(@ptrFromInt(rsdt_ptr.xsdt_addr));
            },
            else => {}
}
        offset = (offset + tag.size + 7) & ~@as(u32, 7); 
    }
    return boot_info;
}

extern const __phys_base: u8;
extern const __phys_end:  u8;

fn validate_rsdp(rsdp: *const RsdpV2) void {
    if (!std.mem.eql(u8, &rsdp.v1.signature, "RSD PTR ")) {
        @panic("ACPI Error: Infalid RSDP Signature!");
    }
    const ptr_bytes: [*]const u8 = @ptrCast(rsdp);
    if (!verifyChecksum(ptr_bytes, 20)) {
        @panic("ACPI Error: RSDP v1 Checksum failed!");
    }

    if (rsdp.v1.revision >= 2) {
        if (!verifyChecksum(ptr_bytes, rsdp.length)) {
            @panic("ACPI Error: RSDP v2 extended checksum failed!");
        }
    }
}

fn verifyChecksum(ptr: [*]const u8, len: usize) bool {
    var sum: u8 = 0;
    for (0..len) |i| {
        sum +%= ptr[i];
    }
    return sum == 0;
}

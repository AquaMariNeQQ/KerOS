const PAGES_PER_CHUNK = @import("buddy.zig").PAGES_PER_CHUNK;
const MAX_CHUNKS = @import("buddy.zig").MAX_CHUNKS;
const Page = @import("buddy.zig").Page;


pub fn get_page(chunks: *const [MAX_CHUNKS]?*Page, phys_addr: *anyopaque) ?*Page {
    const real_phys_addr = @intFromPtr(phys_addr) & ~@as(u64, 4095);
    const chunk_idx = real_phys_addr / (PAGES_PER_CHUNK*4096);
    const page_idx = (real_phys_addr / 4096) % PAGES_PER_CHUNK;
    if (chunk_idx >= MAX_CHUNKS) return null;
    const chunk = chunks[@intCast(chunk_idx)];
    if (chunk) |ch| {
        const chunks_from_current: [*]Page = @ptrCast(ch);
        return &chunks_from_current[page_idx];
    } else {
        return null;
    }
}

pub fn get_addr_from_page(page: *Page, list: *const [MAX_CHUNKS]?*Page) ?*anyopaque {
    const metadata_base = list[page.chunk] orelse return null;
    const base_ptr: [*]Page = @ptrCast(metadata_base);
    const p_ptr: [*]Page = @ptrCast(page);
    const page_idx_in_chunk = p_ptr - base_ptr;
    const chunk_start = page.chunk * PAGES_PER_CHUNK * 4096;
    const page_addr = chunk_start + page_idx_in_chunk * 4096;
    return @ptrFromInt(page_addr);
}


fn get_buddy(chunks: *[MAX_CHUNKS]*Page, page: *Page) ?*Page {
    const current_pfn = get_addr_from_page(page, chunks) / 4096;
    const buddy_pfn = current_pfn ^ (@as(u32, 1) << @intCast(page.order));
    return get_page(chunks, buddy_pfn * 4096);
}

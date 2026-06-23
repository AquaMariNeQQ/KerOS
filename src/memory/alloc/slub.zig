const PHYS_OFFSET = @import("../../utils.zig").PHYS_OFFSET;
const get_page = @import("utils.zig").get_page;
const get_addr_from_page = @import("utils.zig").get_addr_from_page;
const Page = @import("buddy.zig").Page;
const MAX_CHUNKS = @import("buddy.zig").MAX_CHUNKS;
const AllocationSize = @import("../memory.zig").AllocationSize;
const assert = @import("std").debug.assert;
const ALLOCATOR = @import("../memory.zig").ALLOCATOR;
const CPU_DATA = @import("../../smp/percpu.zig").CPU_DATA;
const CurrentData = @import("../../arch.zig").PCDSource;
const IntrusiveList = @import("../../datastructs/intrusive_linked_list.zig").IntrusiveList;
const toVirt = @import("../../utils.zig").toVirt;
const toPhys = @import("../../utils.zig").toPhys;
pub const SlabCache = struct {
    /// Current page
    active_page: ?*Page, // Текущая страница, откуда берем объекты
    /// Free object list inside the current page
    free_list: ?*u64,    // Указывает на свободный объект ВНУТРИ active_page
    /// Partially used pages.
    partial_pages: IntrusiveList(Page), // Страницы, где есть свободные места
    /// Free pages AMOUNT (for stats)
    free_pages: u16,
    /// Object size ( = 1 << cache index + 3)
    obj_size: usize,
    const Self = @This();
    pub fn new(size: usize) Self {
        return Self {
            .active_page = null,
            .free_list = null,
            .partial_pages = undefined,
            .free_pages = 0,
            .obj_size = size,
        };
    }
};

pub const SlubAllocator = struct {
    /// Caches for objects 8B..2KB
    caches: [9]SlabCache,
    /// CPU ID
    cpu_id: u8,
    /// Chunks link; to the ALLOCATOR's field
    chunks: *const [MAX_CHUNKS]?*Page,
    /// For deallocating from the other cores
    remote_free_heads: [9]?*u64,
    const Self = @This();
    fn collect_remote(self: *Self) void {
        var lists: [9]?*u64 = @splat(null);
        for (&self.remote_free_heads, 0..) |*head, index| {
            lists[index] = @atomicRmw(?*u64, head, .Xchg, null, .acquire);
        }
        for (0..9) |idx| {
            var curr_obj = lists[idx];
            while (curr_obj) |real_obj| {
                const next_obj: *u64 = @ptrFromInt(real_obj.*);
                const phys_addr = @intFromPtr(real_obj) - PHYS_OFFSET;
                const page = get_page(self.chunks, @ptrFromInt(phys_addr)) orelse @panic("hell 56");
                const old_usage = page.usage;
                page.usage -= 1;
                const cache = &self.caches[idx];
                if (page == cache.active_page) {
                    real_obj.* = @intFromPtr(cache.free_list);
                    cache.free_list = real_obj;
                } else {
                    real_obj.* = @intFromPtr(page.free_list_head);
                    page.free_list_head = real_obj;
                }
                const objsize_u16: u16 = @intCast(cache.obj_size);
                const max_objs = 4096 / objsize_u16;
                if (old_usage == max_objs and page != cache.active_page) {
                    cache.partial_pages.push_back(page);
                }
                if (page.usage == 0) {
                    cache.free_pages += 1;
                }
                curr_obj = next_obj;
            }
        }
    }
    fn refill(self: *Self, order: u8) void {
        self.collect_remote();

        const cache = &self.caches[order];
        if (cache.free_list == null) {
            if (!cache.partial_pages.isEmpty()) {
                const page: *Page = cache.partial_pages.pop_front() orelse @panic("hell 91");
                const page_list = page.free_list_head;
                cache.free_list = @ptrCast(page_list);
                cache.active_page = page;
                page.free_list_head = null;
                //  if got - return; if not - --->
            } else {
                const cpudata = CurrentData.getPerCpu();
                if (cpudata.local_buddy.alloc(._4KB)) |allocated| {
                    cache.free_pages += 1;
                    const page = get_page(self.chunks, allocated);
                    if (page) |realpage| {
                        realpage.usage = 0;
                        realpage.free_list_head = null;
                        const obj_amount = 4096 / cache.obj_size;
                        const base_addr = toVirt(allocated);
                        for (0..obj_amount) |obj| { // 4096 - page size; 4096 / cache.obj_size = obj_amount
                            const obj_addr = @intFromPtr(base_addr) + obj*cache.obj_size;
                            const objaddr: *u64 = @ptrFromInt(obj_addr);
                            objaddr.* = @intFromPtr(realpage.free_list_head);
                            realpage.free_list_head = objaddr;
                        }
                        cache.free_list = realpage.free_list_head;
                        cache.active_page = realpage;
                        realpage.free_list_head = null;
                    } else {
                        return;
                    }
                }
            }
        }
    }
    fn send_remote(_: *Self, object: *u64, page: *Page, object_order: usize) void {
        const data = CPU_DATA[page.owner_id];
        if (data) |target_data| {
            const target_list = &target_data.local_slub.remote_free_heads[object_order];
            var current_head = @atomicLoad(u64, target_list, .monotonic);
            while (true) {
                object.* = current_head;
                if (@cmpxchgWeak(u64, target_list, current_head, @intFromPtr(object), .release, .monotonic)) |actual_value| {
                    // Неудача: кто-то вклинился, actual_value теперь содержит новую голову
                    current_head = actual_value;
                } else {
                    // Успех: current_head заменен на object
                    break;
                }
            }
        }
    }
    pub fn alloc(self: *Self, size: AllocationSize) ?*anyopaque {
        const sizeu = @intFromEnum(size);
        assert(sizeu < 9);
        if (self.caches[sizeu].free_list == null) {
            self.refill(sizeu);
        }
        const cache = &self.caches[sizeu];
        const maybe_obj = cache.free_list;
        if (maybe_obj) |obj| {
            if (cache.active_page) |act_page| {
                if (act_page.usage == 0) {
                    const actual_page = get_page(self.chunks, toPhys(obj)) orelse @panic("hell 157");
                    actual_page.usage += 1;
                    cache.free_pages -= 1;
                } else {
                    act_page.usage += 1;
                }
            }
            cache.free_list = @ptrFromInt(obj.*);
            return toPhys(obj);
        } else {
            return null;
        }
    }
    fn dealloc(self: *Self, addr: *u64, size: AllocationSize) void {
        assert(@intFromEnum(size) < 9);
        const maybe_page = get_page(self.chunks, addr);
        if (maybe_page) |page| {
            const cache = &self.caches[size];
            if (page.owner_id != self.cpu_id) {
                self.send_remote(toVirt(addr), page, size);
                return;
            } else {
                // put it in the corresponding cache, decrease active page's usage, check if it's free, maybe modify free_pages
                if (page == cache.active_page) {
                    toVirt(addr).* = cache.free_list;
                    cache.free_list = toVirt(addr);
                } else {
                    toVirt(addr).* = page.free_list_head;
                    page.free_list_head = toVirt(addr);
                }
                const old_usage = page.usage;
                const max_objs = @as(u16, 4096 / cache.obj_size);
                page.usage -= 1;
                if (old_usage == max_objs and page != cache.active_page) {
                    cache.partial_pages.push_back(page);
                }
                if (page.usage == 0) {
                    cache.free_pages += 1;
                }
            }
            if (cache.free_pages >= 8) {
                var maybe_partial_page: ?*Page = cache.partial_pages.lookup_front();
                while (maybe_partial_page) |realpage| {
                    if (cache.free_pages <= 2) break;
                    const next = realpage.list_node.next;
                    if (realpage.usage == 0 and realpage != cache.active_page) {
                        cache.partial_pages.remove(realpage);
                        cache.free_pages -= 1;
                        const phys_addr = get_addr_from_page(realpage, self.chunks);
                        CurrentData.getPerCpu().local_buddy.dealloc(phys_addr, ._4KB);
                    }
                    maybe_partial_page = next;
                }
            // free 6 (or more, depending on how many there are, but it's somewhere about 3 / 4) of them to the buddy
            }
        }
    }
    pub fn new(cpu_id: u8) Self {
        const metadata_chunks = ALLOCATOR.lock().get_chunks_ptr();
        ALLOCATOR.unlock();
        return Self {
            .caches = .{
                SlabCache.new(8),    // _8B
                SlabCache.new(16),   // _16B
                SlabCache.new(32),   // _32B
                SlabCache.new(64),   // _64B
                SlabCache.new(128),  // _128B
                SlabCache.new(256),  // _256B
                SlabCache.new(512),  // _512B
                SlabCache.new(1024), // _1KB
                SlabCache.new(2048), // _2KB
            },
            .cpu_id = cpu_id,
            .chunks = metadata_chunks,
            .remote_free_heads = @splat(null),
        };
    }
};



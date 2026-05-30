const BUDDY_LEVELS = @import("buddy.zig").BUDDY_LEVELS;
const MAX_CHUNKS = @import("buddy.zig").MAX_CHUNKS;
const get_addr_from_page = @import("buddy.zig").get_addr_from_page;
const AllocationSize = @import("buddy.zig").AllocationSize;
const get_page = @import("buddy.zig").get_page;
const ALLOCATOR = @import("alloc.zig").ALLOCATOR;
const get_buddy = @import("buddy.zig").get_buddy;
const assert = @import("std").debug.assert;
const IntrusiveList = @import("intrusive_linked_list.zig").IntrusiveList;
const Page = @import("buddy.zig").Page;


pub const CpuLocalBuddyAllocator = struct  {
    free_lists: [BUDDY_LEVELS]IntrusiveList(Page),

    metadata_chunks: *const [MAX_CHUNKS]?*Page,

    free_pages_count: usize,
    cpu_id: u8,

    remote_free_list: ?*Page,
    const Self = @This();

    fn collect_from_remote_list(self: *Self) void {
        var head = @atomicRmw(?*Page, self.remote_free_list, .Xchg, null, .acquire);
        while (head) |page| {
            const next: ?*Page = page.list_node.next;
            assert(page.check_magic());
            const order = page.order;
            self.free_pages_count += @as(usize, 1) << @intCast(order);
            self.internal_free(page);
            head = next;
        }
    }

    fn internal_free(self: *Self, page: *Page) void {
        var final_order = page.order;
        var current_pfn: u64 = get_addr_from_page(page, self.metadata_chunks) / 4096;
        for (page.order..AllocationSize._4MB.to_buddy_size()) |current_order| {
            const buddy_pfn = current_pfn ^ (@as(u64, 1) << @intCast(current_order));
            const buddy_ptr: *Page = get_page(self.metadata_chunks, buddy_pfn * 4096) orelse break;
            assert(buddy_ptr.check_magic());
            if (buddy_ptr.flags.is_free and buddy_ptr.owner_id == self.cpu_id and buddy_ptr.order == current_order) {
                self.free_lists[current_order].remove(buddy_ptr);
                const no_owner = buddy_ptr.flags.no_owner;
                buddy_ptr.flags = .{.no_owner = no_owner, .is_free = false};
                current_pfn &= ~(@as(u64, 1) << @intCast(current_order));
                final_order = @as(u8, current_order) + @as(u8, 1);
            } else {
                break;
            }
        }
        const final_page_ptr = get_page(self.metadata_chunks,current_pfn * 4096);
        if (final_page_ptr) |real_page| {
            const no_owner = real_page.flags.no_owner;
            real_page.flags = .{.no_owner = no_owner, .is_free = true};
            real_page.owner_id = self.cpu_id;
            real_page.order = final_order;
            real_page.set_magic();
            self.free_lists[final_order].push_front(real_page);
        }
    }

    fn refill(self: *Self, target: AllocationSize) void {
        // fast way
        self.collect_from_remote_list();
        var any_full = false;
        for (@intCast((target.to_buddy_size()))..BUDDY_LEVELS) |i| {
            if (!self.free_lists[i].isEmpty()) {any_full = true; break;}
        }
        if (any_full) { return; }
        // slow way
        {
            var addrs = [4]u64{0};
            var is_success = false;
            var current_order: usize = @intFromEnum(AllocationSize._4MB);
            {
                var allocator = ALLOCATOR.lock();
                defer allocator.unlock();
                var current = AllocationSize._4MB.to_buddy_size();
                const end = AllocationSize._4KB.to_buddy_size();
                while (true) {
                    for (0..4) |i| {
                        const maybe_addr = allocator.alloc(AllocationSize.from_buddy_order(current)) orelse break;
                        is_success = true;
                        addrs[i] = maybe_addr;
                    }
                    if (is_success) {
                        current_order = current + @intFromEnum(AllocationSize._4KB);
                        break;
                    }
                    if (current == end) break;
                    current-=1;
                }
            }
            if (is_success) {
                for (addrs) |addr| {
                    if (addr != 0) {
                        const page: *Page = get_page(self.metadata_chunks, addr) orelse @panic("hell 318");
                        const pages_in_block = @as(usize, 1) << (@as(usize, current_order) - (@intFromEnum(AllocationSize._4KB)));
                        for (0..pages_in_block) |i| {
                            const pages: [*]Page = @ptrCast(page);
                            const p = &pages[i];
                            p.set_magic();
                            p.owner_id = self.cpu_id;
                            p.flags = .{.is_free = false, .no_owner = false};
                        }
                        self.free_pages_count += pages_in_block;
                        const no_owner = page.flags.no_owner;
                        page.flags = .{.no_owner = no_owner, .is_free = true};
                        const order_idx: usize = (current_order - @intFromEnum(AllocationSize._4KB));
                        page.order = @intCast(order_idx);
                        self.free_lists[order_idx].push_front(page);
                    }
                }
            }
        }
    }
    fn return_page(chunks: *[MAX_CHUNKS]?*Page, addr: *Page) u16 {
        const final_order = addr.order;
        // return this page to the global buddy;
        addr.owner_id = 0;
        const page_addr: u64 = get_addr_from_page(addr, chunks);
        const order = addr.order;
        assert(page_addr % (@as(u64, 1) << (@as(u6, @intCast(addr.order)) + 12)) == 0);
        const pages: [*]Page = @ptrCast(addr);
        for (0..(1 << order)) |i| {
            const p = &pages[i];
            p.owner_id = 0;
            p.flags = .{.is_free = true, .no_owner = true};
        }
        var allocator = ALLOCATOR.lock();
        defer allocator.unlock();
        allocator.dealloc(page_addr, AllocationSize.from_buddy_order(final_order));
        return @as(u16, 1) << @intCast(final_order);
    }
    fn send_remote(self: *Self, page: *Page) void {
        const @"_" = self;
        const owner_id = page.owner_id;
        const target_data = CPU_DATA[@intCast(owner_id)] orelse @panic("hell 364");
        assert(target_data != null);
        const target_list = &target_data.local_buddy.remote_free_list;
        var current_head = @atomicLoad(?*Page, target_list, .monotonic);
        while (true) {
            page.list_node.next = current_head;
            if (@cmpxchgWeak(?*Page, target_list, current_head,
                page, .release,.monotonic)) |actual_head| {
                current_head = actual_head;
            } else {
                break;
            }
        }
    }
    fn alloc(self: *Self, order: AllocationSize) ?*anyopaque {
        assert(@intFromEnum(order) >= @intFromEnum(AllocationSize._4KB));
        var any_full = false;
        for ((order.to_buddy_size())..BUDDY_LEVELS) |i| {
            if (!self.free_lists[i].isEmpty()) {any_full = true; break;}
        }
        if (!any_full) { self.refill(order); }
        for (order.to_buddy_size()..AllocationSize._4MB.to_buddy_size() + 1) |current_order| {
            if (!self.free_lists[current_order].isEmpty()) {

                const page: *Page = self.free_lists[current_order].pop_front() orelse @panic("hell 486");
                if (page) |real_page|{
                    assert(real_page.check_magic());
                    assert(real_page.owner_id == self.cpu_id);
                    if (!real_page.flags.no_owner) {
                        const pages: [*]Page = @ptrCast(real_page);
                        var current = current_order - @as(usize, 1);
                        const end = order.to_buddy_size();
                        while (current >= end) : (current -= 1)  {
                            const sec_page = &pages[@as(usize, 1) << current];
                            sec_page.order = current;
                            const no_owner = sec_page.flags.no_owner;
                            sec_page.flags = .{.no_owner = no_owner, .is_free = true};
                            sec_page.set_magic();
                            self.free_lists[current].push_back(sec_page);
                        }
                        self.free_pages_count -= @as(usize, 1) << @intCast(order.to_buddy_size());
                        const no_owner = real_page.flags.no_owner;

                        real_page.flags = .{.no_owner = no_owner, .is_free = false};
                        real_page.order = order.to_buddy_size();
                        return get_addr_from_page(real_page, self.metadata_chunks);
                    } else {
                        self.free_lists[current_order].push_front(real_page);
                    }
                } else {
                    @panic("hell 415");
                }
            }
        }
        return null;
    }
    fn dealloc(self: *Self, addr: ?*anyopaque, size: AllocationSize) void {
        const real_addr = addr orelse return;
        // get the first block
        assert(@intFromEnum(size) >= @intFromEnum(AllocationSize._4KB));
        const page: *Page = get_page(self.metadata_chunks, real_addr);
        if (page.owner_id != self.cpu_id) {
            self.send_remote(page);
            return;
        }
        self.free_pages_count += @as(usize, 1) << @intCast(size.to_buddy_size());
        self.internal_free(page);
        if (self.free_pages_count > 5 * 1024) {
            self.collect_from_remote_list();
            var order_idx = AllocationSize._4MB.to_buddy_size();
            while (true) {
                const order_list = &self.free_lists[order_idx];
                var current: ?*Page = order_list.lookup_front(); // обязан возвращать ?*Page
                if (self.free_pages_count <= 4096) { break; }
                while (current) |current_page| {
                    if (self.free_pages_count <= 4096) { break; }

                    // Сохраняем "следующего", пока "текущий" еще жив
                    const next_node = current_page.list_node.next;
                    const buddy = get_buddy(self.metadata_chunks, current_page);
                    // Если соседа нет (край памяти), или он занят другим ядром,
        // или мы уже достигли максимума (4MB) — отдаем.
                    const should_return = buddy == null
                        or buddy.?.owner_id != self.cpu_id
                        or current_page.order == AllocationSize._4MB.to_buddy_size();

                    if (should_return) {
                        order_list.remove(current_page);
                        self.free_pages_count -= @as(usize, 1) << current_page.order;
                        Self.return_page(self.metadata_chunks, current_page);
                    }

                    current = next_node;
                }
                if (order_idx == 0) break;
                order_idx -= 1;
            }
        }
    }
    fn new(cpu_id: u8) Self {
        var allocator = ALLOCATOR.lock();
        const metadata_chunks = allocator.get_chunks_ptr();
        allocator.unlock();
        var s = Self {
            .free_lists = blk: {
                var lists: [BUDDY_LEVELS]IntrusiveList(Page) = undefined;
                for (&lists) |*l| {
                    l.* = IntrusiveList(Page).init();
                }
                break :blk lists;
            },
            .metadata_chunks = metadata_chunks,
            .free_pages_count = 0,
            .cpu_id = cpu_id,
            .remote_free_list = null,
        };
        s.refill(AllocationSize._4MB);
        return s;
    }
};
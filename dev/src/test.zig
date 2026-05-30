const std = @import("std");
const buddy_mod = @import("buddy.zig"); // твой аллокатор

var backing_memory: [1024 * 1024 * 64]u8 = undefined; // 64MB
test "buddy allocator stress test" {
    var allocator = buddy_mod.BuddyAllocator.new();

    // Создаем "физическую память"
    // Допустим, 64MB: 0-1MB Reserved, 1-32MB Usable, 32-33MB Bad, 33-64MB Usable
    const base = @intFromPtr(&backing_memory);

    var regions: [64]?buddy_mod.MemoryRegion = undefined;

    // 1. Reserved (не трогаем)
    regions[0] = .{ .start = base, .end = base + 1 * 1024 * 1024, .kind = .Reserved };

    // 2. Usable (аллоцируем здесь)
    regions[1] = .{ .start = base + 1 * 1024 * 1024, .end = base + 32 * 1024 * 1024, .kind = .Usable };

    // 3. Bad (дырка)
    regions[2] = .{ .start = base + 32 * 1024 * 1024, .end = base + 33 * 1024 * 1024, .kind = .BadMemory };

    // 4. Usable (аллоцируем здесь)
    regions[3] = .{ .start = base + 33 * 1024 * 1024, .end = base + 64 * 1024 * 1024, .kind = .Usable };

    buddy_mod.add_boot_regions(&allocator, &regions);
    try dumpState(&allocator);
    // Стресс-тест: аллоцируем кучу блоков
    var pointers = blk: {
        var lst: [16]?*anyopaque = undefined;
        for (&lst) |*ls| {
            ls.* = null;
        }
        break :blk lst;
    };

    try dumpState(&allocator);

    // Делаем аллокации
    for (0..16) |i| {
        pointers[i] = allocator.alloc(._4KB);
        if (pointers[i]) |ptr| {
            // Проверка: указатель не должен быть в зоне Reserved или Bad
            const addr = @intFromPtr(ptr);
            std.debug.assert(addr >= base + 1 * 1024 * 1024);
            std.debug.assert(addr < base + 32 * 1024 * 1024 or addr >= base + 33 * 1024 * 1024);
        }
    }
    try dumpState(&allocator);

    // Рандомная деаллокация
    for (0..8) |i| {
        if (pointers[i]) |ptr| {
            allocator.dealloc(ptr, ._4KB);
            pointers[i] = null;
        }
    }

    // Проверка, что после деаллокации блоки вернулись (они должны появиться в дампе)
    try dumpState(&allocator);

    // Аллоцируем снова, чтобы проверить переиспользование
    for (0..8) |i| {
        pointers[i] = allocator.alloc(._4KB);
        std.debug.assert(pointers[i] != null);
    }
}

fn dumpState(allocator: *buddy_mod.BuddyAllocator) !void {
    std.debug.print("=== BUDDY STATE ===\n", .{});
    for (&allocator.free_lists, 0..) |*list, order| {
        const size = @as(usize, 4096) << @intCast(order);
        std.debug.print("Order {d} ({d} bytes): ", .{order, size});
        var count: usize = 0;
        var node = list.head;
        while (node) |page| {
            count += 1;
            std.debug.print("0x{x} ", .{@intFromPtr(page)});
            node = page.list_node.next;
        }
        std.debug.print("({d} blocks)\n", .{count});
    }
    std.debug.print("===================\n", .{});
}
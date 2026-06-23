const IntrusiveNode = @import("../datastructs/intrusive_linked_list.zig").IntrusiveNode;
const IntrusiveList = @import("../datastructs/intrusive_linked_list.zig").IntrusiveList;
const PerCpuData = @import("../arch.zig").PCDSource;
const println = @import("../utils.zig").println;

pub fn int_dispatch(frame: *anyopaque, vector: u64) callconv(.c) void {
    var handler: ?*InterruptHandler = InterruptRegistry.handlers[vector].lookup_front();
    while (handler) |h| {
        h.handler(frame);
        handler = h.list_node.next;
    }
    const ic = PerCpuData.getPerCpu().local_ic;
    if (ic.isHardwareInterrupt(ic.ptr, @intCast(vector))) {
        ic.eoi(ic.ptr); // todo: figure out why the fuck the EOI doesn't work properly
    }
}

const ilist = IntrusiveList(InterruptHandler);
var InterruptRegistry = Dispatcher {
    .handlers = @splat(ilist.init())
};

const Dispatcher = struct {
    handlers: [256]IntrusiveList(InterruptHandler),
};

pub fn subscribe(vector: u64, handler: *InterruptHandler) void {
    InterruptRegistry.handlers[vector].push_back(handler);
}

pub fn unsubscribe(vector: u64, handler: *InterruptHandler) void {
    InterruptRegistry.handlers[vector].remove(handler);
}


pub const InterruptHandler = struct {
    handler: *const fn(frame: *anyopaque) void,
    list_node: IntrusiveNode(InterruptHandler)
};
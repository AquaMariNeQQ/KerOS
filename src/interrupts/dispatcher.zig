const IntrusiveNode = @import("../datastructs/intrusive_linked_list.zig").IntrusiveNode;
const IntrusiveList = @import("../datastructs/intrusive_linked_list.zig").IntrusiveList;
const println = @import("../utils.zig").println;

pub fn int_dispatch(frame: *anyopaque, vector: u64) callconv(.c) void {
    var handler: ?*InterruptHandler = InterruptRegistry.handlers[vector].lookup_front();
    while (handler) |h| {
        h.handler(frame);
        handler = h.list_node.next;
    }
}

var InterruptRegistry = Dispatcher {
    .handlers = blk: {
        var lsts: [256]IntrusiveList(InterruptHandler) = undefined;
        for (&lsts) |*lst| {
            lst.head = null;
            lst.tail = null;
        }
        break :blk lsts;
    }
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
pub fn IntrusiveNode(comptime T: anytype) type {
    return struct {
        next: ?*T,
        prev: ?*T,
    };
}

pub fn IntrusiveList(comptime T: anytype) type {
    comptime {
        if (!@hasField(T, "list_node")) {
            @compileError("Тип " ++ @typeName(T) ++
                "должен содержать поле 'list_node'! IntrusiveNode("
                ++ @typeName(T) ++
                ")' для использования в IntrusiveList!");
        }
        if (@FieldType(T, "list_node") != IntrusiveNode(T)) {
            @compileError("Поле 'list_node' в типе "
                ++ @typeName(T) ++
                " должно иметь тип IntrusiveNode(" ++
                @typeName(T) ++ ")");
        }
    }
    return struct {
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();
        pub fn init() Self {
            return .{};
        }


        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }

        pub fn pop_back(self: *Self) ?*T {
            const tail = self.tail orelse return null;
            const prev = tail.list_node.prev;
            if (prev) |prev_ptr| {
                self.tail = prev_ptr;
                prev_ptr.list_node.next = null;
            } else {
                self.head = null;
                self.tail = null;
            }
            tail.list_node.prev = null;
            tail.list_node.next = null;
            return tail;
        }
        pub fn push_back(self: *Self, value: *T) void {
            value.list_node.prev = self.tail;
            value.list_node.next = null;
            if (self.tail) |tail_ptr| {
                tail_ptr.list_node.next = value;
            } else {
                self.head = value;
            }
            self.tail = value;
        }
        pub fn pop_front(self: *Self) ?*T {
            const head = self.head orelse return null;

            const next = head.list_node.next;
            if (next) |real_next| {
                self.head = real_next;
                real_next.list_node.prev = null;
            } else {
                self.head = null;
                self.tail = null;
            }
            head.list_node.prev = null;
            head.list_node.next = null;
            return head;
        }
        pub fn push_front(self: *Self, value: *T) void {
            value.list_node.next = self.head;
            value.list_node.prev = null;
            if (self.head) |real_head| {
                real_head.list_node.prev = value;
            } else {
                self.tail = value;
            }
            self.head = value;
        }

        pub fn remove(self: *Self, value: *T) void {
            const prev = value.list_node.prev;
            const next = value.list_node.next;
            if (prev) |existing_prev| {
                existing_prev.list_node.next = next;
            }
            if (next) |existing_next| {
                existing_next.list_node.prev = prev;
            }
            if (self.tail == value) {
                self.tail = prev;
            }
            if (self.head == value) {
                self.head = next;
            }
            value.list_node.next = null;
            value.list_node.prev = null;
        }
        pub fn lookup_front(self: *Self) ?*T {
            return self.head;
        }
    };
}

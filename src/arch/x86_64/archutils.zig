pub const Port = struct {
    port: u16,
    pub fn outb(self: *@This(), val: u8) void {
        asm volatile ("outb %[val], %[port]"
            :
            : [val] "{al}" (val),
              [port] "N{dx}" (self.port)
        );
    }
    pub fn inb(self: *@This()) u8 {
        return asm volatile ("inb %[port], %[ret]"
            : [ret] "={al}" (-> u8)
            : [port] "{dx}" (self.port)
        );
    }
    pub fn outw(self: *@This(), val: u16) void {
        asm volatile ("outw %[val], %[port]"
            :
            : [val] "{ax}" (val),
              [port] "N{dx}" (self.port)
        );
    }
};

pub fn writeBytes(str: []const u8) void {
    var port = Port{.port = 0x3fd};
    var rport = Port{.port = 0x3f8};
    for (str) |byte| {
        while (port.inb() & 0x20 == 0) {}
        rport.outb(byte);
    }
}
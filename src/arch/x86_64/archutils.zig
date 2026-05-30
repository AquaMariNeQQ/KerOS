
fn serialRead(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8)
        : [port] "{dx}" (port)
    );
}

fn serialWrite(port: u16, byte: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [port] "{dx}" (port),
          [val] "{al}" (byte)
    );
}

pub fn print(str: []const u8) void {
    for (str) |byte| {
        while (serialRead(0x3FD) & 0x20 == 0) {}
        serialWrite(0x3F8, byte);
    }
}
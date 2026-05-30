pub const AbstractPageFlags = packed struct {
    writable: bool = false,
    user_accessable: bool = false,
    write_through: bool = false,
    no_cache: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    global: bool = false,
    executable: bool = false,
    padding: u8 = 0
};

pub const MapError = error {
    overlap,
    out_of_memory,
    invalid_alignment,
    page_not_present,
    unexpected_huge_page,
};

pub const AddrSpace = struct {
    root: *anyopaque,
};

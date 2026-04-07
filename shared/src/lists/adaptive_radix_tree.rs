use crate::multicore::AllocationSize::{_128B, _1KB, _256B, _2KB};
use crate::multicore::{AllocationSize, CpuLocalAllocator};
use crate::memory::paging::ArchConfig;
use core::cmp::PartialEq;
use core::marker::PhantomData;
use core::ptr::{addr_of_mut, write_bytes};

#[macro_export]
macro_rules! get_node_ptr {
    ($ptr:expr, $idx:expr) => {
        match $ptr.get_type() {
            ARTNodeType::Node12 => &mut (*$ptr.get_addr::<ARTNode12, E>()).children[$idx],
            ARTNodeType::Node24 => &mut (*$ptr.get_addr::<ARTNode24, E>()).children[$idx],
            ARTNodeType::Node72 => &mut (*$ptr.get_addr::<ARTNode72, E>()).children[$idx],
            ARTNodeType::Node256 => &mut (*$ptr.get_addr::<ARTNode256, E>()).children[$idx],
            _ => unreachable!("Not a node type"),
        }
    };
}

#[derive(Eq, PartialEq, Copy, Clone, Debug)]
pub enum Side {
    Left,
    Right,
}

#[derive(Debug)]
pub enum TreeError {
    Overlap,           // Попытка замапить то, что уже занято
    NotFound,          // Адрес не принадлежит ни одному региону
    OutOfMemory,       // Slub/Buddy пуст
    InvalidRange,      // end <= start или адрес вне канонической формы
    StorageFull,       // Достигнут лимит записей (sysctl_max_map_count)
    Contention,        // Ошибка при попытке захвата лока (если используешь Lock-Free)
}

/// Базовый интерфейс ART (Key-Value)
pub trait AdaptiveRadixTree<K, V>
where
    K: Into<u64> + Copy
{
    unsafe fn insert<A: CpuLocalAllocator>(&mut self, key: K, value: V, alloc: &mut A) -> Result<(), TreeError>;
    unsafe fn get(&self, key: K) -> Option<&V>;
    unsafe fn remove<A: CpuLocalAllocator>(&mut self, key: K, alloc: &mut A) -> Result<V, TreeError>;
    fn new() -> Self;
}
/// ART Pointer,
/// ``expand documentation here``
pub struct ARTPointer<E: ArchConfig>(pub u64, PhantomData<E>);


impl<E: ArchConfig> ARTPointer<E> {
    pub fn from_addr(addr: u64, typ: ARTNodeType) -> Self {
        let mut s = Self::new(addr);
        s.set_type(typ);
        s
    }

    pub fn new(ptr: u64) -> Self<> {
        ARTPointer(ptr, PhantomData)
    }

    pub fn get_addr<T>(&self) -> *mut T {
        let mut addr = self.0 & E::ADDR_MASK;
        if (addr >> E::SIGN_BIT) & 1 != 0 {
            addr |= !E::ADDR_MASK;
        }
        addr as *mut T
    }
    pub unsafe fn find_child(&self, byte: u8) -> Option<ARTPointer<E>> {
        if self.is_null() || self.get_type() == ARTNodeType::Leaf { return None };
        match self.get_type() {
            ARTNodeType::Node12 => {
                (*self.get_addr::<ARTNode12<E>>()).find_child(byte, self)
            }
            ARTNodeType::Node24 => {
                (*self.get_addr::<ARTNode24<E>>()).find_child(byte, self)
            }
            ARTNodeType::Node72 => {
                (*self.get_addr::<ARTNode72<E>>()).find_child(byte, self)
            }
            ARTNodeType::Node256 => {
                (*self.get_addr::<ARTNode256<E>>()).find_child(byte, self)
            }
            _ => unreachable!()
        }
    }
    pub unsafe fn get_child_mut(&mut self, byte: u8) -> Option<&mut ARTPointer<E>> {
        if self.is_null() || self.get_type() == ARTNodeType::Leaf { return None };
        match self.get_type() {
            ARTNodeType::Node12 => {
                (*self.get_addr::<ARTNode12<E>>()).get_child_mut(byte, self)
            }
            ARTNodeType::Node24 => {
                (*self.get_addr::<ARTNode24<E>>()).get_child_mut(byte, self)
            }
            ARTNodeType::Node72 => {
                (*self.get_addr::<ARTNode72<E>>()).get_child_mut(byte, self)
            }
            ARTNodeType::Node256 => {
                (*self.get_addr::<ARTNode256<E>>()).get_child_mut(byte, self)
            }
            _ => unreachable!()
        }
    }
    pub unsafe fn add_child(&mut self, byte: u8, child_ptr: Self) {
        match self.get_type() {
            ARTNodeType::Node12 => {
                let node = &mut *self.get_addr::<ARTNode12<E>>();
                node.add_child(byte, child_ptr, self);
            }
            ARTNodeType::Node24 => {
                let node = &mut *self.get_addr::<ARTNode24<E>>();
                node.add_child(byte, child_ptr, self);
            }
            ARTNodeType::Node72 => {
                let node = &mut *self.get_addr::<ARTNode72<E>>();
                node.add_child(byte, child_ptr, self);
            }
            ARTNodeType::Node256 => {
                let node = &mut *self.get_addr::<ARTNode256<E>>();
                node.add_child(byte, child_ptr, self);
            }
            ARTNodeType::Leaf => unreachable!()
        }
    }

    const TAG_MASK: u64 = 0b111;
    const COUNT_SHIFT: u32 = 48;
    const COUNT_MASK: u64 = 0xFFFF_0000_0000_0000;

    pub fn get_type(&self) -> ARTNodeType {
        match self.0 & Self::TAG_MASK {
            0 => ARTNodeType::Node12,
            1 => ARTNodeType::Node24,
            2 => ARTNodeType::Node72,
            3 => ARTNodeType::Node256,
            _ => ARTNodeType::Leaf,
        }
    }
    pub fn set_type(&mut self, t: ARTNodeType) {
        self.0 = (self.0 & !Self::TAG_MASK) | (t as u64);
    }

    pub unsafe fn get_count(&self) -> u16 {
        (self.0 >> Self::COUNT_SHIFT) as u16
    }

    pub unsafe fn set_count(&mut self, count: u16) {
        let clean_ptr = self.0 & !Self::COUNT_MASK;
        self.0 = clean_ptr | ((count as u64) << Self::COUNT_SHIFT);
    }

    pub fn is_null(&self) -> bool {
        self.0 == 0
    }
}


#[repr(u64)]
#[derive(Debug, PartialEq, Eq, Copy, Clone)]
pub enum ARTNodeType {
    Node12 = 0b000,
    Node24 = 0b001,
    Node72 = 0b010,
    Node256 = 0b011,
    Leaf = 0b100,
}

impl ARTNodeType {
    pub fn get_alloc_size(&self) -> AllocationSize {
        assert_ne!(self, &ARTNodeType::Leaf, "Why?");
        match self {
            ARTNodeType::Node12 => { _128B }
            ARTNodeType::Node24 => { _256B }
            ARTNodeType::Node72 => { _1KB }
            ARTNodeType::Node256 => { _2KB }
            ARTNodeType::Leaf => unimplemented!(),
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            ARTNodeType::Node12 => {"Node 12"}
            ARTNodeType::Node24 => {"Node 24"}
            ARTNodeType::Node72 => {"Node 72"}
            ARTNodeType::Node256 => {"Node 256"}
            ARTNodeType::Leaf => {"Leaf"}
        }
    }
    pub fn get_count(&self) -> usize {
        assert_ne!(self, &ARTNodeType::Leaf, "How?");
        match self {
            ARTNodeType::Node12 => { 12 }
            ARTNodeType::Node24 => { 24 }
            ARTNodeType::Node72 => { 72 }
            ARTNodeType::Node256 => { 256 }
            ARTNodeType::Leaf => unimplemented!(),
        }
    }
}

#[repr(C, align(4))]
pub struct ARTNodeHeader {
    /// Длина сжатого пути (префикса)
    pub prefix_len: u32,
    /// Сам префикс (Path Compression). Для 64-битных адресов 8-10 байт обычно хватает.
    pub prefix: [u8; 8],
}

#[repr(C)]
pub struct ARTNode12<E: ArchConfig> {
    pub header: ARTNodeHeader,
    pub keys: [u8; 12],
    pub children: [ARTPointer<E>; 12],
}

impl<E: ArchConfig> ARTNode<E> for ARTNode12<E> {
    unsafe fn find_child(&self, byte: u8, selfptr: &ARTPointer<E>) -> Option<ARTPointer<E>> {
        for i in 0..selfptr.get_count() as usize {
            if self.keys[i] == byte {
                return Some(self.children[i]);
            }
        }
        None
    }
    unsafe fn get_child_mut(&mut self, byte: u8, selfptr: &ARTPointer<E>) -> Option<&mut ARTPointer<E>> {
        for i in 0..selfptr.get_count() as usize {
            if self.keys[i] == byte {
                return Some(&mut self.children[i]);
            }
        }
        None
    }
    unsafe fn remove_child(&mut self, byte: u8, selfptr: &mut ARTPointer<E>) -> u8 {
        let count = selfptr.get_count();
        assert_ne!(count, 0, "[ASSERTION]: COUNT FOR ARTNode12 is zero!");
        for i in 0..count as usize {
            if self.keys[i] == byte {
                let last_idx = count as usize - 1;
                if i != last_idx {
                    self.keys[i] = self.keys[last_idx];
                    self.children[i] = self.children[last_idx];
                }
                self.children[last_idx] = ARTPointer::new(0);
                self.keys[last_idx] = 0;
                selfptr.set_count(last_idx as u16);
                return i as u8;
            }
        }
        0
    }

    fn header(&self) -> &ARTNodeHeader { &self.header }

    unsafe fn add_child(&mut self, byte: u8, child: ARTPointer<E>, selfptr: &mut ARTPointer<E>) {
        let count = selfptr.get_count();
        assert!(count < 12, "[ASSERTION]: COUNT FOR ARTNode12 is already 12 or more!");
        self.keys[count as usize] = byte;
        self.children[count as usize] = child;
        selfptr.set_count(count+1);
    }

    unsafe fn is_full(&self, selfptr: &ARTPointer<E>) -> bool {
        selfptr.get_count() == 12
    }

    unsafe fn new<A: CpuLocalAllocator>(alloc: &mut A) -> Result<*mut Self, TreeError>{
        if let Some(node) = alloc.alloc_virtual(ARTNodeType::Node12.get_alloc_size()) {
            let node = node.as_u64() as *mut Self;
            write_bytes(node, 0, 1);
            Ok(node)
        } else { Err(TreeError::OutOfMemory) }
    }
}
#[repr(C)]
pub struct ARTNode24<E: ArchConfig> {
    pub header: ARTNodeHeader,
    pub keys: [u8; 24],
    pub children: [ARTPointer<E>; 24],
}

impl<E: ArchConfig> ARTNode<E> for ARTNode24<E> {
    unsafe fn find_child(&self, byte: u8, selfptr: &ARTPointer<E>) -> Option<ARTPointer<E>> {
        for i in 0..selfptr.get_count() as usize {
            if self.keys[i] == byte {
                return Some(self.children[i]);
            }
        }
        None
    }
    unsafe fn get_child_mut(&mut self, byte: u8, selfptr: &ARTPointer<E>) -> Option<&mut ARTPointer<E>> {
        for i in 0..selfptr.get_count() as usize {
            if self.keys[i] == byte {
                return Some(&mut self.children[i]);
            }
        }
        None
    }

    fn header(&self) -> &ARTNodeHeader { &self.header }
    unsafe fn add_child(&mut self, byte: u8, child: ARTPointer<E>, selfptr: &mut ARTPointer<E>) {
        let count = selfptr.get_count();
        assert!(self.keys.iter().find(|&&x| x == byte).is_none(), "[ASSERTION]: Tried to add already existing byte to the node24!");
        assert!(count < 24, "[ASSERTION]: COUNT FOR ARTNode24 is already 24 or more!");
        self.keys[count as usize] = byte;
        self.children[count as usize] = child;
        selfptr.set_count(count+1);
    }

    unsafe fn remove_child(&mut self, byte: u8, selfptr: &mut ARTPointer<E>) -> u8 {
        let count = selfptr.get_count();
        assert_ne!(count, 0, "[ASSERTION]: COUNT FOR ARTNode24 is zero!");
        for i in 0..count as usize {
            if self.keys[i] == byte {
                let last_idx = count as usize - 1;
                if i != last_idx {
                    self.keys[i] = self.keys[last_idx];
                    self.children[i] = self.children[last_idx];
                }
                self.children[last_idx] = ARTPointer::new(0);
                self.keys[last_idx] = 0;
                selfptr.set_count(last_idx as u16);
                return i as u8;
            }
        }
        0
    }

    unsafe fn is_full(&self, selfptr: &ARTPointer<E>) -> bool {
        selfptr.get_count() == 24
    }

    unsafe fn new<A: CpuLocalAllocator>(alloc: &mut A) -> Result<*mut Self, TreeError>{
        if let Some(node) = alloc.alloc_virtual(ARTNodeType::Node24.get_alloc_size()) {
            let node = node.as_u64() as *mut Self;
            write_bytes(node, 0, 1);
            Ok(node)
        } else { Err(TreeError::OutOfMemory) }
    }

}

#[repr(C)]
pub struct ARTNode72<E: ArchConfig> {
    pub header: ARTNodeHeader,
    /// Массив индексов: 255 означает "пусто", 0..47 — индекс в children
    pub index: [u8; 256],
    pub children: [ARTPointer<E>; 72],
    pub mask: [u64; 4],
}

impl<E: ArchConfig> ARTNode<E> for ARTNode72<E> {
    unsafe fn find_child(&self, byte: u8, _: &ARTPointer<E>) -> Option<ARTPointer<E>> {
        let idx = self.index[byte as usize];
        if idx == u8::MAX { return None }
        let child = self.children[idx as usize];
        if child.is_null() { None } else { Some(child) }
    }
    unsafe fn get_child_mut(&mut self, byte: u8, _: &ARTPointer<E>) -> Option<&mut ARTPointer<E>> {
        let idx = self.index[byte as usize];
        if idx == u8::MAX { return None }
        let child = &mut self.children[idx as usize];
        if child.is_null() { None } else { Some(child) }
    }
    fn header(&self) -> &ARTNodeHeader { &self.header }

    unsafe fn add_child(&mut self, byte: u8, child: ARTPointer<E>, selfptr: &mut ARTPointer<E>) {
        let count = selfptr.get_count();
        assert!(count < 72, "[ASSERTION]: COUNT FOR ARTNode72 is already 72 or more!");
        assert_eq!(self.index[byte as usize], u8::MAX, "[ASSERTION]: Tried to replace some other child in Node72!");
        self.index[byte as usize] = count as u8;
        self.children[count as usize] = child;
        self.mask[byte as usize / 64] |= 1 << (byte % 64);
        selfptr.set_count(count+1);
    }

    unsafe fn remove_child(&mut self, byte: u8, selfptr: &mut ARTPointer<E>) -> u8 {
        let count = selfptr.get_count();
        assert_ne!(count, 0, "[ASSERTION]: COUNT FOR ARTNode72 is zero!");
        let last_idx = (count -1) as u8;
        let idx = self.index[byte as usize];
        self.index[byte as usize] = u8::MAX;
        if idx != last_idx {
            self.children[idx as usize] = self.children[last_idx as usize];
            for el in self.index.iter_mut() {
                if *el == last_idx {
                    *el = idx;
                    break;
                }
            }
        }
        self.mask[byte as usize / 64] &= !(1 << (byte % 64));
        self.children[last_idx as usize] = ARTPointer::new(0);
        selfptr.set_count(count-1);
        byte
    }

    unsafe fn is_full(&self, selfptr: &ARTPointer<E>) -> bool {
        selfptr.get_count() == 72
    }
    unsafe fn new<A: CpuLocalAllocator>(alloc: &mut A) -> Result<*mut Self, TreeError>{
        if let Some(node) = alloc.alloc_virtual(ARTNodeType::Node72.get_alloc_size()) {
            let node = node.as_u64() as *mut Self;
            write_bytes(node, 0, 1);
            write_bytes(/*
                addr_of_mut!() returns a pointer to an object.
                here it has got an array ([u8; 256]) so it will return *mut [u8; 256]
            */addr_of_mut!((*node).index), 0xFF, 1);
            Ok(node)
        } else { Err(TreeError::OutOfMemory) }
    }
}

#[repr(C)]
pub struct ARTNode256<E: ArchConfig> {
    pub children: [ARTPointer<E>; 256],
}

impl<E: ArchConfig> ARTNode<E> for ARTNode256<E> {
    unsafe fn find_child(&self, byte: u8, _: &ARTPointer<E>) -> Option<ARTPointer<E>> {
        let child = self.children[byte as usize];
        if child.is_null() { None } else { Some(child) }
    }
    unsafe fn get_child_mut(&mut self, byte: u8, _: &ARTPointer<E>) -> Option<&mut ARTPointer<E>> {
        let child = &mut self.children[byte as usize];
        if child.is_null() { None } else { Some(child) }
    }

    unsafe fn add_child(&mut self, byte: u8, child: ARTPointer<E>, selfptr: &mut ARTPointer<E>) {
        assert!(selfptr.get_count() < 256, "[ASSERTION]: COUNT FOR ARTNode256 is already 256!");
        assert!(self.children[byte as usize].is_null(), "[ASSERTION]: Tried to replace some other child in Node256!");
        self.children[byte as usize] = child;
        selfptr.set_count(selfptr.get_count() + 1);
    }

    unsafe fn is_full(&self, selfptr: &ARTPointer<E>) -> bool {
        selfptr.get_count() == 256
    }

    unsafe fn resolve_prefix(&self, _: u64, _: &mut i32) -> Result<(), TreeError> { unimplemented!() }
    fn header(&self) -> &ARTNodeHeader { unimplemented!() }

    unsafe fn new<A: CpuLocalAllocator>(alloc: &mut A) -> Result<*mut Self, TreeError>{
        if let Some(node) = alloc.alloc_virtual(ARTNodeType::Node256.get_alloc_size()) {
            let node = node.as_u64() as *mut Self;
            write_bytes(node, 0, 1);
            Ok(node)
        } else { Err(TreeError::OutOfMemory) }
    }

    unsafe fn remove_child(&mut self, byte: u8, selfptr: &mut ARTPointer<E>) -> u8 {
        self.children[byte as usize] = ARTPointer::new(0);
        selfptr.set_count(selfptr.get_count()-1);
        byte
    }
}

pub trait ARTNode<E: ArchConfig> {
    unsafe fn find_child(&self, byte: u8, selfptr: &ARTPointer<E>) -> Option<ARTPointer<E>>;
    unsafe fn get_child_mut(&mut self, byte: u8, selfptr: &ARTPointer<E>) -> Option<&mut ARTPointer<E>>;
    fn header(&self) -> &ARTNodeHeader;
    unsafe fn add_child(&mut self, byte: u8, child: ARTPointer<E>, selfptr: &mut ARTPointer<E>);
    unsafe fn remove_child(&mut self, byte: u8, selfptr: &mut ARTPointer<E>) -> u8;
    unsafe fn is_full(&self, selfptr: &ARTPointer<E>) -> bool;
    unsafe fn resolve_prefix(&self, key: u64, depth: &mut i32) -> Result<(), TreeError> {
        if self.header().prefix_len == 0 { return Ok(()); };
        for i in 0..self.header().prefix_len {
            let shift = (E::SIGN_BIT as i32 - 7) - (*depth * 8);
            if shift < 0 { return Err(TreeError::NotFound); }

            let key_byte = (key >> shift) as u8;
            if self.header().prefix[i as usize] != key_byte {
                return Err(TreeError::NotFound);
            }
            *depth += 1;
        }
        Ok(())
    }
    unsafe fn new<A: CpuLocalAllocator>(alloc: &mut A) -> Result<*mut Self, TreeError>;
}

impl<E: ArchConfig> Copy for ARTPointer<E> {}
impl<E: ArchConfig> Clone for ARTPointer<E> {
    fn clone(&self) -> Self { *self }
}
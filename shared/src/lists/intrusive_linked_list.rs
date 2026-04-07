use core::ptr::null_mut;

pub trait List<T> {
    fn new() -> Self;
    unsafe fn pop_back(&mut self) -> *mut T;
    unsafe fn push_back(&mut self, value: *mut T);
    unsafe fn pop_front(&mut self) -> *mut T;
    unsafe fn push_front(&mut self, value: *mut T);
    fn is_empty(&self) -> bool;
    unsafe fn remove(&mut self, value: *mut T);
    unsafe fn lookup_front(&mut self) -> *mut T;
}

#[derive(Copy, Clone)]
pub struct IntrusiveNode<T> {
    pub next: *mut T,
    pub prev: *mut T,
}
impl<T> IntrusiveNode<T> {
    pub const fn new() -> Self{
        Self {
            next: null_mut(),
            prev: null_mut(),
        }
    }
}
#[derive(Copy, Clone)]
pub struct IntrusiveList<T: IntrusiveNodeAccess> {
    head: *mut T,
    tail: *mut T,
}

pub trait IntrusiveNodeAccess {
    fn get_node(&self) -> *const IntrusiveNode<Self> where Self: Sized;
    fn get_node_mut(&mut self) -> *mut IntrusiveNode<Self> where Self: Sized;
}
impl<T: IntrusiveNodeAccess> IntrusiveList<T> {
    pub const fn new() -> Self {
        Self {
            head: null_mut(),
            tail: null_mut()
        }
    }
}

impl<T: IntrusiveNodeAccess> List<T> for IntrusiveList<T> {
    fn new() -> Self {
        Self::new()
    }

    unsafe fn pop_back(&mut self) -> *mut T {
        if self.tail.is_null() { return null_mut() }

        let tail = self.tail;
        let node = (*tail).get_node_mut();
        let prev = (*node).prev;
        if prev.is_null() {
            self.head = null_mut();
            self.tail = null_mut();
        } else {
            self.tail = prev;
            (*(*prev).get_node_mut()).next = null_mut();
        }
        (*node).prev = null_mut();
        (*node).next = null_mut();
        tail
    }
    unsafe fn push_back(&mut self, value: *mut T) {
        let node = (*value).get_node_mut();
        (*node).prev = self.tail;
        (*node).next = null_mut();
        if self.tail.is_null() {
            self.head = value
        } else {
            let next = (*self.tail).get_node_mut();
            (*next).next = value;
        }
        self.tail = value
    }
    unsafe fn pop_front(&mut self) -> *mut T {
        if self.head.is_null() { return null_mut() }

        let head = self.head;
        let node = (*head).get_node_mut();
        let next = (*node).next;
        if next.is_null() {
            self.head = null_mut();
            self.tail = null_mut();
        } else {
            self.head = next;
            (*(*next).get_node_mut()).prev = null_mut();
        }
        (*node).prev = null_mut();
        (*node).next = null_mut();
        head
    }
    unsafe fn push_front(&mut self, value: *mut T) {
        let node = (*value).get_node_mut();
        (*node).next = self.head;
        (*node).prev = null_mut();
        if self.head.is_null() {
            self.tail = value
        } else {
            let next = (*self.head).get_node_mut();
            (*next).prev = value;
        }
        self.head = value
    }
    fn is_empty(&self) -> bool {
        self.head == null_mut()
    }
    unsafe fn remove(&mut self, value: *mut T) {
        let node_ptr = (*value).get_node_mut();
        let prev = (*node_ptr).prev;
        let next = (*node_ptr).next;
        if !prev.is_null() {
            (*(*prev).get_node_mut()).next = next;
        }
        if !next.is_null() {
            (*(*next).get_node_mut()).prev = prev;
        }
        if self.tail == value {
            self.tail = prev;
        }
        if self.head == value {
            self.head = next;
        }
        (*node_ptr).next = null_mut();
        (*node_ptr).prev = null_mut();
    }
    unsafe fn lookup_front(&mut self) -> *mut T {
        self.head
    }
}
use core::cell::UnsafeCell;
use core::hint::spin_loop;
use core::ops::{Deref, DerefMut};
use core::sync::atomic::AtomicBool;
use core::sync::atomic::Ordering::{Acquire, Relaxed, Release};

pub struct Spinlock<T> {
    lock: AtomicBool,
    data: UnsafeCell<T>,
}

impl<T> Spinlock<T> {
    pub const fn new(data: T) -> Self {
        Self {
            lock: AtomicBool::new(false),
            data: UnsafeCell::new(data)
        }
    }
    pub fn lock(&'_ self) -> SpinGuard<'_, T> {
        while self.lock.compare_exchange(false, true, Acquire, Relaxed).is_err() {
            spin_loop();
        }
        SpinGuard { parent: self }
    }
    pub fn try_lock(&'_ self) -> Option<SpinGuard<'_, T>> {
        if !self.lock.compare_exchange(false, true, Acquire, Relaxed).is_err() {
            return Some(SpinGuard { parent: self })
        }
        None
    }
}

pub struct SpinGuard<'a, T> {
    parent: &'a Spinlock<T>
}
impl<T> Deref for SpinGuard<'_, T> {
    type Target = T;
    fn deref(&self) -> &Self::Target {
        unsafe { &*self.parent.data.get() }
    }
}
impl<T> DerefMut for SpinGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { &mut *self.parent.data.get() }
    }
}

impl<T> Drop for SpinGuard<'_, T> {
    fn drop(&mut self) {
        self.parent.lock.store(false, Release)
    }
}

unsafe impl<T: Send> Sync for Spinlock<T> {}
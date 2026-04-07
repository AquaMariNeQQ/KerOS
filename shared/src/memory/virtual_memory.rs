use crate::lists::adaptive_radix_tree::{ARTNode, ARTNode12, ARTNode24, ARTNode256, ARTNode72, ARTNodeHeader, ARTNodeType, ARTPointer, AdaptiveRadixTree, Side, TreeError};
use crate::multicore::{AllocationSize, CpuLocalAllocator};
use crate::memory::paging::{ArchConfig, MappingFlags};
use crate::VirtAddr;
use core::ptr;
use core::ptr::{copy_nonoverlapping, write_bytes};

pub trait RangeObject<E> {
    fn start(&self) -> E;
    fn end(&self) -> E;
    fn size(&self) -> usize;
}

impl<E: ArchConfig> VMMRadixTree<E> {
    unsafe fn resolve_prefix(node_ptr: &ARTPointer<E>, key: u64, depth: &mut i32) -> Result<(), TreeError> {
        match node_ptr.get_type() {
            ARTNodeType::Node12 => {
                let node = &*(node_ptr.get_addr::<ARTNode12<E>>());
                node.resolve_prefix(key, depth)
            }
            ARTNodeType::Node24 => {
                let node = &*(node_ptr.get_addr::<ARTNode24<E>>());
                node.resolve_prefix(key, depth)
            }
            ARTNodeType::Node72 => {
                let node = &*(node_ptr.get_addr::<ARTNode72<E>>());
                node.resolve_prefix(key, depth)
            }
            ARTNodeType::Node256 | ARTNodeType::Leaf => unreachable!()
        }
    }

    /// spaghetti... mamma mia
    unsafe fn grow_node<A: CpuLocalAllocator>(node_ptr: &ARTPointer<E>, alloc: &mut A) -> Result<ARTPointer<E>, TreeError> {
        match node_ptr.get_type() {
            ARTNodeType::Node12 => {
                let old_node = &*node_ptr.get_addr::<ARTNode12<E>>();
                let new_node_ptr = ARTNode24::new(alloc)?;
                let new_node = &mut *new_node_ptr;
                let count = node_ptr.get_count() as usize;
                new_node.header.prefix = old_node.header.prefix;
                new_node.header.prefix_len = old_node.header.prefix_len;
                new_node.keys[..count].copy_from_slice(&old_node.keys);
                new_node.children[..count].copy_from_slice(&old_node.children);
                let mut new_ptr = ARTPointer::from_addr(new_node_ptr as u64, ARTNodeType::Node24);
                new_ptr.set_count(count as u16);
                alloc.dealloc_virtual(VirtAddr::new(node_ptr.get_addr::<ARTNode12<E>>() as u64), ARTNodeType::Node12.get_alloc_size());
                Ok(new_ptr)
            }
            ARTNodeType::Node24 => {
                let old_node = &*node_ptr.get_addr::<ARTNode24<E>>();
                let new_node_ptr = ARTNode72::new(alloc)?;
                let new_node = &mut *new_node_ptr;
                let count = node_ptr.get_count() as usize;
                new_node.header.prefix = old_node.header.prefix;
                new_node.header.prefix_len = old_node.header.prefix_len;
                for i in 0..count {
                    let byte = old_node.keys[i];
                    new_node.mask[byte as usize / 64] |= 1 << (byte % 64);
                    new_node.index[byte as usize] = i as u8;
                    new_node.children[i] = old_node.children[i];
                }
                let mut new_ptr = ARTPointer::from_addr(new_node_ptr as u64, ARTNodeType::Node72);
                new_ptr.set_count(count as u16);
                alloc.dealloc_virtual(VirtAddr::new(node_ptr.get_addr::<ARTNode24<E>>() as u64), ARTNodeType::Node24.get_alloc_size());
                Ok(new_ptr)
            }
            ARTNodeType::Node72 => {
                let old_node = &*node_ptr.get_addr::<ARTNode72<E>>();
                let new_node_ptr = ARTNode256::new(alloc)?;
                let new_node = &mut *new_node_ptr;
                let count = node_ptr.get_count() as usize;
                for i in 0..=255 {
                    let index = old_node.index[i];
                    if index != u8::MAX {
                        new_node.children[i] = old_node.children[index as usize];
                    }
                }
                let mut new_ptr = ARTPointer::from_addr(new_node_ptr as u64, ARTNodeType::Node256);
                new_ptr.set_count(count as u16);
                if old_node.header.prefix_len > 0 {
                    let head_prefix_len = old_node.header.prefix_len - 1;
                    let head_node_ptr = ARTNode12::<E>::new(alloc)?;
                    let head_node = &mut *head_node_ptr;
                    head_node.header.prefix_len = head_prefix_len;
                    copy_nonoverlapping(
                        old_node.header.prefix.as_ptr(),
                        head_node.header.prefix.as_mut_ptr(),
                        head_prefix_len as usize
                    );
                    let connector_byte = old_node.header.prefix[head_prefix_len as usize];
                    let mut head_ptr = ARTPointer::<E>::from_addr(head_node_ptr as u64, ARTNodeType::Node12);
                    head_node.add_child(connector_byte, new_ptr, &mut head_ptr);
                    alloc.dealloc_virtual(VirtAddr::new(node_ptr.get_addr::</*type here doesn't matter, but still*/ARTNode72<E>>() as u64),
                                          ARTNodeType::Node72.get_alloc_size());
                    return Ok(head_ptr);
                };
                alloc.dealloc_virtual(VirtAddr::new(node_ptr.get_addr::</*type here doesn't matter, but still*/ARTNode72<E>>() as u64),
                                      ARTNodeType::Node72.get_alloc_size());
                Ok(new_ptr)
            }
            ARTNodeType::Node256 => unimplemented!(),
            ARTNodeType::Leaf => unimplemented!("Questionable. maybe should be implemented")
        }
    }
    unsafe fn get_neighbour(node_ptr: &ARTPointer<E>, side: Side, byte: u8) -> Option<VirtualRegion> {
        let mut node_ptr = *node_ptr;
        match node_ptr.get_type() {
            ARTNodeType::Node12 => {
                let node = &*node_ptr.get_addr::<ARTNode12<E>>();
                let mut extreme = byte;
                let mut extr_index = 0;
                for i in 0..node_ptr.get_count()  {
                    if (node.keys[i as usize] < extreme && side == Side::Left) || (node.keys[i as usize] > extreme && side == Side::Right) {
                        extreme = node.keys[i as usize];
                        extr_index = i;
                    }
                }
                if extreme == byte { return None; }
                node_ptr = node.children[extr_index as usize];
            }
            ARTNodeType::Node24 => {
                let node = &*node_ptr.get_addr::<ARTNode24<E>>();
                let mut extreme = byte;
                let mut extr_index = 0;
                for i in 0..node_ptr.get_count()  {
                    if (node.keys[i as usize] < extreme && side == Side::Left) || (node.keys[i as usize] > extreme && side == Side::Right) {
                        extreme = node.keys[i as usize];
                        extr_index = i;
                    }
                }
                if extreme == byte { return None; }
                node_ptr = node.children[extr_index as usize];
            }
            ARTNodeType::Node72 => {
                let node = &*node_ptr.get_addr::<ARTNode72<E>>();
                let word_idx = (byte / 64) as usize;
                let bit_in_word = (byte % 64) as u32;
                let mut target_byte: Option<usize> = None;

                if side == Side::Left {
                    // 1. Проверяем текущее слово (только биты младше bit_in_word)
                    let mask = node.mask[word_idx] & ((1 << bit_in_word) - 1);
                    if mask != 0 {
                        target_byte = Some((word_idx << 6) | (63 - mask.leading_zeros() as usize));
                    } else {
                        // 2. Ищем в словах слева
                        for i in (0..word_idx).rev() {
                            if node.mask[i] != 0 {
                                target_byte = Some((i << 6) | (63 - node.mask[i].leading_zeros() as usize));
                                break;
                            }
                        }
                    }
                } else {
                    // 1. Проверяем текущее слово (только биты старше bit_in_word)
                    let mask = if bit_in_word < 63 {
                        node.mask[word_idx] & (!0 << (bit_in_word + 1))
                    } else {
                        0
                    };
                    if mask != 0 {
                        target_byte = Some((word_idx << 6) | (mask.trailing_zeros() as usize));
                    } else {
                        // 2. Ищем в словах справа
                        for i in (word_idx + 1)..4 {
                            if node.mask[i] != 0 {
                                target_byte = Some((i << 6) | (node.mask[i].trailing_zeros() as usize));
                                break;
                            }
                        }
                    }
                }

                if let Some(b) = target_byte {
                    node_ptr = node.children[node.index[b] as usize];
                } else { return None; }
            }
            ARTNodeType::Node256 => {
                let node = &*node_ptr.get_addr::<ARTNode256<E>>();
                let mut i = byte as usize;
                let mut found = false;
                while i <= 255 {
                    if side == Side::Right && i < 255 {
                        i += 1;
                    } else if side == Side::Left && i != 0 {
                        i -= 1;
                    } else { return None; }
                    if !node.children[i].is_null() {
                        found = true; break;
                    }
                }
                if found {
                    node_ptr = node.children[i];
                } else { return None; }
            }
            ARTNodeType::Leaf => {
                return Some(*node_ptr.get_addr::<VirtualRegion>())
            }
        };
        Self::get_extreme(node_ptr, if side == Side::Right {Side::Left} else {Side::Right})
    }
    unsafe fn get_extreme(node_ptr: ARTPointer<E>, side: Side) -> Option<VirtualRegion> {
        let mut node_ptr = node_ptr;
        loop {
            match node_ptr.get_type() {
                ARTNodeType::Node12 => {
                    let node = &*node_ptr.get_addr::<ARTNode12<E>>();
                    let mut extr_id = 0;
                    let mut found = false;
                    for i in 0..node_ptr.get_count()  {
                        if (side == Side::Left && node.keys[i as usize] < node.keys[extr_id]) ||
                            (side == Side::Right && node.keys[i as usize] > node.keys[extr_id]) {
                            extr_id = i as usize;
                            found = true;
                        }
                    }
                    if !found { return None; }
                    node_ptr = node.children[extr_id];
                }
                ARTNodeType::Node24 => {
                    let node = &*node_ptr.get_addr::<ARTNode24<E>>();
                    let mut extr_id = 0;
                    let mut found = false;
                    for i in 0..node_ptr.get_count()  {
                        if (side == Side::Left && node.keys[i as usize] < node.keys[extr_id]) ||
                            (side == Side::Right && node.keys[i as usize] > node.keys[extr_id]) {
                            extr_id = i as usize;
                            found = true;
                        }
                    }
                    if !found { return None; }
                    node_ptr = node.children[extr_id];
                }
                ARTNodeType::Node72 => {
                    let node = &*node_ptr.get_addr::<ARTNode72<E>>();
                    let mut target_byte: Option<usize> = None;

                    if side == Side::Left {
                        // Ищем самый младший бит во всей маске
                        for i in 0..4 {
                            if node.mask[i] != 0 {
                                target_byte = Some((i << 6) | (node.mask[i].trailing_zeros() as usize));
                                break;
                            }
                        }
                    } else {
                        // Ищем самый старший бит во всей маске
                        for i in (0..4).rev() {
                            if node.mask[i] != 0 {
                                target_byte = Some((i << 6) | (63 - node.mask[i].leading_zeros() as usize));
                                break;
                            }
                        }
                    }

                    if let Some(b) = target_byte {
                        node_ptr = node.children[node.index[b] as usize];
                    } else { return None; }
                }
                ARTNodeType::Node256 => {
                    let node = &*node_ptr.get_addr::<ARTNode256<E>>();
                    let mut found = false;
                    match side {
                        Side::Left => {
                            for i in 0..256 {
                                if !node.children[i].is_null() {
                                    node_ptr = node.children[i];
                                    found = true;
                                    break;
                                }
                            }
                            if !found { return None }

                        }
                        Side::Right => {
                            for i in (0..256).rev() {
                                if !node.children[i].is_null() {
                                    node_ptr = node.children[i];
                                    found = true;
                                    break;
                                }
                            }
                            if !found { return None }

                        }
                    }
                }
                ARTNodeType::Leaf => {
                    return Some(*node_ptr.get_addr::<VirtualRegion>())
                }
            }
        }
    }
    unsafe fn shrink_node<A: CpuLocalAllocator>(node: ARTPointer<E>, alloc: &mut A) -> Result<ARTPointer<E>, TreeError> {
        let count = node.get_count();
        match node.get_type() {
            ARTNodeType::Node24 => {
                let node_ptr = node.get_addr::<ARTNode24<E>>();
                let node_ref = &*node_ptr;
                let new_node_ptr = ARTNode12::new(alloc)?;
                let new_node = &mut *new_node_ptr;
                new_node.header.prefix_len = node_ref.header.prefix_len;
                new_node.header.prefix = node_ref.header.prefix;
                for i in 0..count as usize {
                    new_node.keys[i] = node_ref.keys[i];
                    new_node.children[i] = node_ref.children[i];
                }
                let mut new_node_artptr = ARTPointer::<E>::from_addr(new_node_ptr as u64, ARTNodeType::Node12);
                new_node_artptr.set_count(count);
                alloc.dealloc_virtual(VirtAddr::new(node_ptr as u64), ARTNodeType::Node24.get_alloc_size());
                Ok(new_node_artptr)
            }
            ARTNodeType::Node72 => {
                let node_ptr = node.get_addr::<ARTNode72<E>>();
                let node_ref = &*node_ptr;
                let new_node_ptr = ARTNode24::new(alloc)?;
                let new_node = &mut *new_node_ptr;
                let mut local_count = 0;
                new_node.header.prefix = node_ref.header.prefix;
                new_node.header.prefix_len = node_ref.header.prefix_len;
                for i in 0..256usize {
                    if node_ref.index[i] != u8::MAX {
                        new_node.keys[local_count] = i as u8;
                        new_node.children[local_count] = node_ref.children[node_ref.index[i] as usize];
                        local_count+=1;
                    }
                    if local_count == count as usize {break;};
                }
                let mut new_node_artptr = ARTPointer::<E>::from_addr(new_node_ptr as u64, ARTNodeType::Node24);
                new_node_artptr.set_count(local_count as u16);
                alloc.dealloc_virtual(VirtAddr::new(node_ptr as u64), ARTNodeType::Node72.get_alloc_size());
                Ok(new_node_artptr)
            }
            ARTNodeType::Node256 => {
                let node_ptr = node.get_addr::<ARTNode256<E>>();
                let node_ref = &*node_ptr;
                let new_node_ptr = ARTNode72::<E>::new(alloc)?;
                let new_node = &mut *new_node_ptr;
                let mut local_count = 0;
                for i in 0..256usize {
                    if !node_ref.children[i].is_null() {
                        new_node.index[i] = local_count as u8;
                        new_node.mask[i / 64] |= 1 << (i % 64);
                        new_node.children[local_count] = node_ref.children[i];
                        local_count += 1;
                    }
                    if local_count == count as usize { break; }
                }
                let mut new_node_artptr = ARTPointer::from_addr(new_node_ptr as u64, ARTNodeType::Node72);
                new_node_artptr.set_count(local_count as u16);
                alloc.dealloc_virtual(VirtAddr::new(node_ptr as u64), ARTNodeType::Node256.get_alloc_size());
                Ok(new_node_artptr)
            }
            ARTNodeType::Node12 => {
                let node_ptr = node.get_addr::<ARTNode12<E>>();
                let node_ref = &*node_ptr;
                let node_copy_pr_len = node_ref.header.prefix_len;
                let node_copy_pr = node_ref.header.prefix;
                let node_copy_ft_key = node_ref.keys[0];
                let child = node_ref.children[0];
                alloc.dealloc_virtual(VirtAddr::new(node_ptr as u64), node.get_type().get_alloc_size());
                if count == 0 {
                    return Ok(ARTPointer::new(0));
                }

                if child.get_type() == ARTNodeType::Leaf {
                    let old_reg = child.get_addr::<VirtualRegion>();
                    let leaf_ptr = ARTPointer::from_addr(old_reg as u64, ARTNodeType::Leaf);
                    Ok(leaf_ptr)
                } else {
                    match child.get_type() {
                        ARTNodeType::Node12 | ARTNodeType::Node24 | ARTNodeType::Node72 => {
                            let hdr = &mut *child.get_addr::<ARTNodeHeader>();
                            let parent_len = node_copy_pr_len as usize;
                            let prefix_ptr = hdr.prefix.as_mut_ptr();
                            ptr::copy(
                                prefix_ptr,
                                prefix_ptr.add(parent_len + 1),
                                hdr.prefix_len as usize
                            );
                            copy_nonoverlapping(
                                node_copy_pr.as_ptr(),
                                prefix_ptr,
                                parent_len
                            );
                            *prefix_ptr.add(parent_len) = node_copy_ft_key;
                            hdr.prefix_len += (parent_len + 1) as u32;
                            Ok(child)
                        },
                        ARTNodeType::Leaf => {
                            Ok(child)
                        }
                        ARTNodeType::Node256 => {unreachable!("Node256 doesn't have a header -> it, as a child of node12, can't be shrunk (path is incompressible)")}
                    }
                }
            },
            ARTNodeType::Leaf => unreachable!("Why?")
        }
    }
    unsafe fn check_overlap_from_stack(
        stack: &[Option<Ancestor<E>>; 8],
        k: usize,
        new_region: &VirtualRegion
    ) -> Result<(), TreeError> {
        let mut found_l = false;
        let mut found_r = false;

        for i in (0..k).rev() {
            // Используем as_ref(), чтобы не забирать владение из стека!
            if let Some(anc) = stack[i].as_ref() {
                if !found_l {
                    if let Some(ln) = Self::get_neighbour(&anc.node, Side::Left, anc.byte) {
                        if ln.end.as_u64() > new_region.start.as_u64() { return Err(TreeError::Overlap); }
                        found_l = true;
                    }
                }
                if !found_r {
                    if let Some(rn) = Self::get_neighbour(&anc.node, Side::Right, anc.byte) {
                        if rn.start.as_u64() < new_region.end.as_u64() { return Err(TreeError::Overlap); }
                        found_r = true;
                    }
                }
            }
            if found_l && found_r { break; }
        }
        Ok(())
    }
    unsafe fn split_and_insert<A: CpuLocalAllocator>(idx: usize, old_node: &ARTPointer<E>, region: VirtualRegion, curr_byte: u8, alloc: &mut A) -> Result<ARTPointer<E>, TreeError> {
        let new_node_ptr = ARTNode12::<E>::new(alloc)?;
        let new_node = &mut *new_node_ptr;
        let old_node_header = &mut *old_node.get_addr::<ARTNodeHeader>();
        copy_nonoverlapping(old_node_header.prefix.as_ptr(), new_node.header.prefix.as_mut_ptr(), idx as usize);
        new_node.header.prefix_len = idx as u32;
        let mismatch_byte = old_node_header.prefix[idx];
        let new_prefix_len = old_node_header.prefix_len - idx as u32 - 1u32;
        if new_prefix_len > 0 {
            ptr::copy(
                old_node_header.prefix.as_ptr().add(idx +1),
                old_node_header.prefix.as_mut_ptr(),
                new_prefix_len as usize,
            )
        }
        old_node_header.prefix_len = new_prefix_len;
        let leaf_ptr = create_leaf::<A, E>(&region, alloc)?;
        let mut split_node_ptr = ARTPointer::<E>::from_addr(new_node_ptr as u64, ARTNodeType::Node12);
        let new_node_ref = &mut *new_node_ptr;
        new_node_ref.add_child(mismatch_byte, *old_node, &mut split_node_ptr);
        new_node_ref.add_child(curr_byte, leaf_ptr, &mut split_node_ptr);

        Ok(split_node_ptr)
    }
}

impl<E: ArchConfig> AdaptiveRadixTree<VirtAddr, VirtualRegion> for VMMRadixTree<E> {
    /// TODO: Оптимизация вставки и проверки пересечений (VMA Overlap Check)
    ///  1. Реализовать Path Stack (стек пройденных узлов) при спуске, чтобы `get_neighbour`
    ///     мог подниматься к родителю, если в текущем узле нет соседей. Это исключит
    ///     необходимость повторного обхода дерева от корня.
    ///  2. Поддерживать `keys` в `Node12` и `Node24` в отсортированном виде.
    ///     Это позволит заменить линейный поиск на `_mm_cmpeq_epi8` (SIMD) или
    ///     бинарный поиск, что критично при больших объемах (тест на 2М+ регионов).
    ///  3. Сейчас проверка оверлапа может потребовать полного обхода, что дает O(k * depth).
    ///     С Path Stack это станет O(depth).
    unsafe fn insert<A: CpuLocalAllocator>(&mut self, key: VirtAddr, value: VirtualRegion, alloc: &mut A) -> Result<(), TreeError> {
        assert!(value.end > value.start, "VMM: Invalid region range: {:x} - {:x}", value.start.as_u64(), value.end.as_u64());
        assert!(key == value.start, "VMM: Key must match region start");
        if self.root.is_null() {
            self.root = create_leaf::<A, E>(&value, alloc)?;
            return Ok(());
        }
        let mut parent_link = &mut self.root;
        let mut depth = 0;
        let key_val = key.as_u64();
        let mut stack: [Option<Ancestor<E>>; 8] = [const{None}; 8];
        let mut k = 0;
        loop {
            let curr_node = *parent_link;
            if curr_node.get_type() != ARTNodeType::Leaf {
                if curr_node.get_count() > curr_node.get_type().get_count() as u16 {
                    panic!("OH FUCK AGAIN? WHAT'S WRONG WITH YOU?")
                }
            }
            let curr_byte = get_byte_at_depth::<E>(key_val, depth as usize)?;
            stack[k] = Some(Ancestor { node: curr_node, byte: curr_byte });
            k+=1;
            match curr_node.get_type() {
                ARTNodeType::Node12 | ARTNodeType::Node24 | ARTNodeType::Node72 => {
                    let old_depth = depth.clone();
                    let hdr= &*curr_node.get_addr::<ARTNodeHeader>();
                    assert!(hdr.prefix_len <= 8);
                    if let Err(_) = Self::resolve_prefix(&curr_node, key_val, &mut depth) {
                        let idx = depth - old_depth;
                        let curr_byte = get_byte_at_depth::<E>(key_val, depth as usize)?;
                        stack[k-1] = Some(Ancestor { node: curr_node, byte: curr_byte });
                            Self::check_overlap_from_stack(&stack, k, &value)?;
                        *parent_link = Self::split_and_insert(idx as usize, &curr_node, value, curr_byte, alloc)?;
                        return Ok(())
                    } else {
                        let curr_byte = get_byte_at_depth::<E>(key_val, depth as usize)?;
                        stack[k-1] = Some(Ancestor { node: curr_node, byte: curr_byte });
                    }
                    if curr_node.get_count() >= curr_node.get_type().get_count() as u16 {
                        let new_ptr = Self::grow_node(&curr_node, alloc)?;

                        // set it up
                        *parent_link = /*maybe?*/ new_ptr;
                        depth = old_depth;
                        continue;
                    }
                    let curr_byte = get_byte_at_depth::<E>(key_val, depth as usize)?;
                    let has_child = parent_link.find_child(curr_byte).is_some();
                    if has_child {
                        let child_ref = parent_link.get_child_mut(curr_byte).unwrap();
                        parent_link = child_ref;
                        depth += 1;
                        continue;
                    } else {
                        Self::check_overlap_from_stack(&stack, k, &value)?;
                        let leaf_ptr: ARTPointer<E> = create_leaf(&value, alloc)?;
                        parent_link.add_child(curr_byte, leaf_ptr);
                        return Ok(());
                    }
                }
                ARTNodeType::Node256 => {
                    if curr_node.get_count() > 256 { return Err(TreeError::StorageFull); }
                    let shift = (E::SIGN_BIT as i32 - 7) - (depth*8);
                    if shift < 0 { return Err(TreeError::Overlap); }
                    let curr_byte = (key_val >> shift) as u8;
                    let has_child = parent_link.find_child(curr_byte).is_some();
                    if has_child {
                        let child_ref = parent_link.get_child_mut(curr_byte).unwrap();
                        parent_link = child_ref;
                        depth += 1;
                        continue;
                    } else {
                        Self::check_overlap_from_stack(&stack, k, &value)?;
                        let leaf_ptr: ARTPointer<E> = create_leaf(&value, alloc)?;
                        parent_link.add_child(curr_byte, leaf_ptr);
                        return Ok(());
                    }
                }
                ARTNodeType::Leaf => {
                    let old_leaf = &*curr_node.get_addr::<VirtualRegion>();
                    let max_start = core::cmp::max(old_leaf.start.as_u64(), value.start.as_u64());
                    let min_end = core::cmp::min(old_leaf.end.as_u64(), value.end.as_u64());
                    if max_start < min_end {
                        return Err(TreeError::Overlap); // Они пересекаются
                    }
                    let old_depth = depth.clone();
                    while (E::SIGN_BIT as i32 - 7) - (depth*8) >= 0 {
                        let shift = (E::SIGN_BIT as i32 - 7) - (depth * 8);
                        if shift < 0 { return Err(TreeError::Overlap); }
                        let old_byte = (old_leaf.start.as_u64() >> shift) as u8;
                        let new_byte = (key_val >> shift) as u8;
                        if old_byte != new_byte { break; }
                        depth +=1;
                    }
                    if depth < old_depth {
                        panic!("DEPTH REGRESSION: depth {}, old_depth {}", depth, old_depth);
                    }
                    let shared_len = depth - old_depth;
                    assert!(shared_len >= 0);
                    let new_node_ptr = ARTNode12::<E>::new(alloc)?;
                    let new_node = &mut *new_node_ptr;
                    new_node.header.prefix_len = shared_len as u32;
                    for i in 0..shared_len {
                        let shift = (E::SIGN_BIT as i32 - 7) - ((old_depth + i) * 8);
                        let byte = (key_val >> shift) as u8;
                        new_node.header.prefix[i as usize] = byte;
                    }
                    let shift = (E::SIGN_BIT as i32 - 7) - (depth * 8);
                    if shift < 0 { return Err(TreeError::Overlap); };
                    let old_byte = (old_leaf.start.as_u64() >> shift) as u8;
                    let new_byte = (key_val >> shift) as u8;
                    let new_leaf = create_leaf::<A, E>(&value, alloc)?;
                    let mut split_ptr = ARTPointer::<E>::from_addr(new_node_ptr as u64, ARTNodeType::Node12);
                    new_node.add_child(old_byte, curr_node, &mut split_ptr);
                    new_node.add_child(new_byte, new_leaf,  &mut split_ptr);
                    *parent_link = split_ptr;
                    return Ok(())
                }
            }
        }
    }

    unsafe fn get(&self, key: VirtAddr) -> Option<&VirtualRegion> {
        let mut curr_node = self.root;
        if curr_node.is_null() { return None }
        let key_val = key.as_u64();
        let mut depth = 0;
        loop {
            if curr_node.get_type() == ARTNodeType::Leaf {
                let reg_ptr = curr_node.get_addr::<VirtualRegion>();
                let region = &*reg_ptr;
                return if key_val >= region.start.as_u64() && key_val < region.end.as_u64() {
                    Some(&region)
                } else {
                    None
                }
            }
            if curr_node.get_type() != ARTNodeType::Node256 {
                if let Err(_) = Self::resolve_prefix(&curr_node, key_val, &mut depth) {
                    return None;
                }
            }
            let shift = (E::SIGN_BIT as i32 - 7) - (depth*8);
            if shift < 0 { return None; }
            let curr_byte = (key_val >> shift) as u8;


            match curr_node.find_child(curr_byte) {
                Some(next_node) => {
                    curr_node = next_node;
                    depth += 1;
                }
                None => {
                    return None},
            };
        }
    }

    unsafe fn remove<A: CpuLocalAllocator>(&mut self, key: VirtAddr, alloc: &mut A) -> Result<VirtualRegion, TreeError> {
        if self.root.is_null() {
            return Err(TreeError::NotFound) };
        let mut parent_ptr: *mut ARTPointer<E> = &mut self.root;
        let mut stack: [Option<Ancestor<E>>; 8] = [const {None}; 8];
        let mut stack_idx = 0;
        let mut depth = 0;
        let key_val = key.as_u64();
        let result = 'search: loop {
            let curr_node = *parent_ptr;
            let node_type = curr_node.get_type();
            if curr_node.get_type() == ARTNodeType::Leaf {
                let reg_ptr = curr_node.get_addr::<VirtualRegion>();
                if (*reg_ptr).start.as_u64() == key_val {
                    if stack_idx == 0 {
                        self.root = ARTPointer::new(0);
                        break Ok(reg_ptr);
                    } else {
                        let reg_ptr = curr_node.get_addr::<VirtualRegion>();
                        if (*reg_ptr).start.as_u64() == key_val {
                            let mut current_byte_to_remove = stack[stack_idx - 1].as_ref().unwrap().byte;
                            let mut ii = stack_idx as i32 - 1;
                            while ii >= 0 {
                                let mut entry = stack[ii as usize].take().unwrap();
                                // 1. Сначала сохраняем старую ноду, чтобы знать, что менять в родителе

                                // 2. Удаляем ребенка (здесь внутри происходит swap элементов в Node12/24)
                                let _ = match entry.node.get_type() {
                                    ARTNodeType::Node12 => (*entry.node.get_addr::<ARTNode12<E>>()).remove_child(current_byte_to_remove, &mut entry.node),
                                    ARTNodeType::Node24 => (*entry.node.get_addr::<ARTNode24<E>>()).remove_child(current_byte_to_remove, &mut entry.node),
                                    ARTNodeType::Node72 => (*entry.node.get_addr::<ARTNode72<E>>()).remove_child(current_byte_to_remove, &mut entry.node),
                                    ARTNodeType::Node256 => (*entry.node.get_addr::<ARTNode256<E>>()).remove_child(current_byte_to_remove, &mut entry.node),
                                    _ => unreachable!()
                                };

                                let count = entry.node.get_count();
                                // 3. Проверка на шринк (ТВОЙ ФИКС ДЛЯ ЛИСТОВ ТУТ)
                                let can_shrink = match entry.node.get_type() {
                                    ARTNodeType::Node256 => count <= 72,
                                    ARTNodeType::Node72 => count <= 24,
                                    ARTNodeType::Node24 => count <= 12,
                                    ARTNodeType::Node12 => {
                                        if count == 0 { true } else if count == 1 {
                                            // Если остался один ребенок - всегда шринкаем (хоть Leaf, хоть Node)
                                            // Исключение только Node256, так как у нее нет заголовка для префикса
                                            let child = (*entry.node.get_addr::<ARTNode12<E>>()).children[0];
                                            child.get_type() != ARTNodeType::Node256
                                        } else { false }
                                    }
                                    _ => false,
                                };

                                if can_shrink {
                                    // ЛОГ: Только если нода реально изменилась или исчезла
                                    let proc_node = Self::shrink_node(entry.node, alloc)?;

                                    // ВАЖНО: Мы заменяем ВЕСЬ указатель на старую ноду в родителе
                                    if ii > 0 {
                                        let parent_entry = stack[ii as usize - 1].as_mut().unwrap();

                                        if proc_node.is_null() {
                                            // Если текущая нода исчезла, удаляем ключ из родителя
                                            // Это и запустит дефрагментацию в родителе на следующей итерации
                                            current_byte_to_remove = parent_entry.byte;
                                        } else if proc_node.0 != entry.node.0 {
                                            // Если нода заменилась на другую (shrink), просто обновляем указатель
                                            // Мы ищем по parent_entry.byte, который в родителе еще ТОЧНО есть
                                            if let Some(child_slot) = parent_entry.node.get_child_mut(parent_entry.byte) {
                                                *child_slot = proc_node;
                                            }
                                            break 'search Ok(reg_ptr); // Указатель обновили, дерево цело, выходим
                                        } else {
                                            break 'search Ok(reg_ptr); // Ничего не изменилось, выходим
                                        }
                                    } else {
                                        self.root = proc_node;
                                        break 'search Ok(reg_ptr);
                                    }
                                } else {
                                    if ii > 0 {
                                        let parent_entry = stack[ii as usize - 1].as_mut().unwrap();
                                        if let Some(child_slot) = parent_entry.node.get_child_mut(parent_entry.byte) {
                                            *child_slot = entry.node;
                                        }
                                        break 'search Ok(reg_ptr); // Указатель обновили, дерево цело, выходим
                                    } else {
                                        self.root = entry.node;
                                        break 'search Ok(reg_ptr);
                                    }
                                }
                                ii -= 1;
                            }
                            break 'search Ok(reg_ptr)
                        } else { break 'search Err(TreeError::NotFound) }
                    }
                } else {
                    Err(TreeError::NotFound)
                }?
            }
            if node_type != ARTNodeType::Node256 && node_type != ARTNodeType::Leaf {
                if let Err(_) = Self::resolve_prefix(&curr_node, key_val, &mut depth) {
                    return Err(TreeError::NotFound);
                }
            }
            let shift = (E::SIGN_BIT as i32 - 7) - (depth * 8);
            if shift < 0 {
                return Err(TreeError::NotFound);
            }
            let curr_byte = (key_val >> shift) as u8;
            stack[stack_idx] = Some(Ancestor {
                node: curr_node,
                byte: curr_byte,
            });
            stack_idx += 1;
            // В цикле спуска, где делаешь stack[stack_idx] = ...
            match (*parent_ptr).get_child_mut(curr_byte) {
                None => {
                    return Err(TreeError::NotFound)
                },
                Some(child) => {
                    parent_ptr = child as *mut ARTPointer<E>;
                    depth += 1;
                }
            }
        };
        if let Ok(res) = result {
            let reg = *res;
            alloc.dealloc_virtual(VirtAddr::new(res as u64), AllocationSize::_32B);
            Ok(reg)
        } else {
            let Err(e) = result else { unreachable!() };
            Err(e)
        }
    }
    fn new() -> Self {
        Self {
            root: ARTPointer::new(0),
        }
    }
}
pub struct VMMRadixTree<E: ArchConfig> {
    pub root: ARTPointer<E>,
}

#[derive(Copy, Clone)]
pub struct VirtualRegion {
    pub start: VirtAddr,
    pub end: VirtAddr,
    pub flags: MappingFlags,
}

impl RangeObject<VirtAddr> for VirtualRegion {
    fn start(&self) -> VirtAddr {
        self.start
    }

    fn end(&self) -> VirtAddr {
        self.end
    }

    fn size(&self) -> usize {
        (self.end.as_u64() - self.start.as_u64()) as usize
    }
}

struct Ancestor<E: ArchConfig> {
    // Сама нода, в которой мы сейчас находимся
    node: ARTPointer<E>,
    // Байт, по которому мы спустились к следующему ребенку
    byte: u8,
}

unsafe fn create_leaf<A: CpuLocalAllocator, E: ArchConfig>(val: &VirtualRegion, alloc: &mut A) -> Result<ARTPointer<E>, TreeError> {
    let ptr = alloc.alloc_virtual(AllocationSize::_32B).ok_or(TreeError::OutOfMemory)?;
    let leaf_ptr = ptr.as_u64() as *mut VirtualRegion;
    write_bytes(leaf_ptr, 0, 1);
    ptr::write(leaf_ptr, val.clone()); // Если VirtualRegion реализует Clone
    Ok(ARTPointer::from_addr(leaf_ptr as u64, ARTNodeType::Leaf))
}

#[inline(always)]
fn get_byte_at_depth<E: ArchConfig>(key: u64, depth: usize) -> Result<u8, TreeError> {
    let shift = (E::SIGN_BIT as i32 - 7) - (depth as i32 * 8);
    if shift < 0 { return Err(TreeError::Overlap); }
    Ok((key >> shift) as u8)
}
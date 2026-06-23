#!/usr/bin/python
ints_push_ecode = {8, 10, 11, 12, 13, 14, 17, 21, 29, 30}
def gen_stub(index: int):
    extra = "" if index in ints_push_ecode else "push 0"
    return f"""
int_stub_{index}:
    {extra}
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rdi, rsp
    mov rsi, {index}
    mov rbx, rsp
    and rsp, -16
    call int_dispatch
    mov rsp, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    add rsp, 8
    iretq
    \n"""
with open("src/arch/x86_64/int_stubs.asm", "w") as f:
    f.write("; DO NOT EDIT THE CONTENTS OF THIS FILE\n")
    f.write("; THEY ARE GENERATED USING THE interrupt_stub_gen.py IN src/arch/x86_64/\n")
    f.write("; ANY CHANGES WILL BE LOST WHEN THIS FILE IS REGENERATED\n")
    f.write("extern int_dispatch\n")
    for i in range(256):
        f.write(f"global int_stub_{i}\n")
        f.write(gen_stub(i))
    f.write("\n\n\n ; stub address array\n")
    f.write("global int_stub_array\n")
    f.write("int_stub_array:\n")
    for i in range(256):
        f.write(f"    dq int_stub_{i}\n")
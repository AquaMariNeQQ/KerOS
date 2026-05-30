// This file exists BECAUSE ZIG COMPILER SUCKS. I WILL REWRITE EVERYTHING IN C OR C++ IF THOSE IDIOT DONT FIX THEIR STUPID BUILD SYSTEM AND EVERYTHING ELSE
// THEIR BUILD SYSTEM: IGNORES LINKER SCRIPTS (except if you use LLVM), MAKES PIC-CODE AND IT CANNOT EVEN DO MEMCPY BY ITSELF. IT, FUCKING, SUCKS
#include <stddef.h>

void* memcpy(void* dest, const void* src, size_t n) {
    unsigned char* d = (unsigned char*)dest;
    const unsigned char* s = (const unsigned char*)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dest;
}

void __zig_probe_stack() {
    // Пустота
}

void *memset(void *s, int c, size_t n) {
    unsigned char *p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dest;
}
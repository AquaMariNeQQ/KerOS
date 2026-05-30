const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const gen_stubs = b.addSystemCommand(&.{"python3", "src/arch/x86_64/interrupt_stub_gen.py"});

    // 2. Функция для сборки ассемблерного файла через NASM
    const nasm_flags = &[_][]const u8{ "-f", "elf64" };

    const boot_obj = b.addSystemCommand(&.{"nasm"});
    boot_obj.addArgs(nasm_flags);
    boot_obj.addArg("src/arch/x86_64/boot.asm");
    boot_obj.addArgs(&.{"-o", "build/arch/x86_64/boot.o"});
    boot_obj.step.dependOn(&b.addSystemCommand(&.{"mkdir", "-p", "build/arch/x86_64"}).step);

    const stubs_obj = b.addSystemCommand(&.{"nasm"});
    stubs_obj.addArgs(nasm_flags);
    stubs_obj.addArg("src/arch/x86_64/int_stubs.asm");
    stubs_obj.addArgs(&.{"-o", "build/arch/x86_64/int_stubs.o"});
    stubs_obj.step.dependOn(&gen_stubs.step); // Сначала генерируем, потом ассемблируем!
    const mkdir_step = b.addSystemCommand(&.{"mkdir", "-p", "build/arch/x86_64", "build/bin"});
    boot_obj.step.dependOn(&mkdir_step.step);
    const kernel = b.addExecutable(.{
        .name = "keros.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .code_model = .large,
            .unwind_tables = .none
        }),
        .use_lld = true,
        .use_llvm = true,
        .linkage = .static,
    });
    kernel.bundle_ubsan_rt = false;
    kernel.bundle_compiler_rt = false;
    kernel.use_new_linker = false;
    kernel.link_gc_sections = false;

    kernel.pie = false;
    kernel.step.dependOn(&boot_obj.step);
    kernel.step.dependOn(&stubs_obj.step);
    kernel.setLinkerScript(b.path("src/arch/x86_64/linker.ld"));
    kernel.root_module.addObjectFile(b.path("build/arch/x86_64/boot.o"));
    kernel.root_module.addObjectFile(b.path("build/arch/x86_64/int_stubs.o"));
    kernel.setVerboseLink(true);

    kernel.root_module.sanitize_c = .off;
    kernel.root_module.addCSourceFile(.{
        .file = b.path("src/arch/x86_64/zigisatrashlanguage.c"),
        .flags = &.{"-ffreestanding", "-nostdlib", "-fno-stack-protector", "-fno-sanitize=undefined",}
    });
    b.exe_dir = "build/bin/";
    b.installArtifact(kernel);
    b.cache_root.path = "build";
    std.debug.print("Compiling...\n", .{});
}
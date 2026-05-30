const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Стандартно получаем таргет и оптимизацию
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 2. Создаем модуль для нашего тестового файла.
    // Теперь вся конфигурация исходников, таргетов и оптимизации инкапсулирована в Module.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 3. Передаем этот модуль в addTest согласно новому API
    const kernel_tests = b.addTest(.{
        .name = "allocator_tests",
        .root_module = test_module,
    });

    // 4. Создаем шаг запуска для получившегося тестового артефакта
    const run_kernel_tests = b.addRunArtifact(kernel_tests);

    // 5. Регистрируем команду 'test'
    const test_step = b.step("test", "Run allocator unit tests");
    test_step.dependOn(&run_kernel_tests.step);
}
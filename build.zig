const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const BenchImplementation = enum {
        original,
        port,
        gpa,
    };
    const bench_implementation = b.option(BenchImplementation, "impl", "Which impl of the benchmark to run") orelse .port;
    const strip = b.option(bool, "strip", "Strip executable");
    const want_lto = b.option(bool, "want-lto", "Enable wanting LTO");
    const single_threaded = b.option(bool, "single-threaded", "Disable threading");
    const emit_asm = b.option(bool, "emit-asm", "Emit assembly");
    const emit_asm_to = b.option([]const u8, "emit-asm-to", "Emit assembly");
    std.debug.assert(
        (emit_asm == null and emit_asm_to == null) or
            (emit_asm != null) != (emit_asm_to != null),
    );

    const zig_bench_impl_leo = b.addStaticLibrary("benchmark-impl-zig", "benchmark/benchmark-impl.zig");
    zig_bench_impl_leo.setBuildMode(mode);
    zig_bench_impl_leo.setTarget(target);
    zig_bench_impl_leo.strip = strip;
    zig_bench_impl_leo.want_lto = want_lto;
    zig_bench_impl_leo.single_threaded = single_threaded;
    zig_bench_impl_leo.emit_asm = if (emit_asm) |cond| (if (cond) .emit else .no_emit) else if (emit_asm_to) |path| .{ .emit_to = path } else .default;
    zig_bench_impl_leo.addPackagePath("rpmalloc", "src/rpmalloc.zig");
    const zig_bench_impl_options = b.addOptions();
    zig_bench_impl_leo.addOptions("build_options", zig_bench_impl_options);
    zig_bench_impl_options.addOption(bool, "port_safety", b.option(bool, "port-safety", "Use GPA as the backing allocator to check for leaks") orelse false);
    switch (bench_implementation) {
        .port, .gpa => {
            zig_bench_impl_options.contents.writer().writeAll(
                \\pub const BenchImplementation = enum {
            ) catch unreachable;
            inline for (@typeInfo(BenchImplementation).Enum.fields) |field| {
                zig_bench_impl_options.contents.writer().print("    {s},", .{field.name}) catch unreachable;
            }
            zig_bench_impl_options.contents.writer().writeAll("};\n") catch unreachable;
            zig_bench_impl_options.contents.writer().print(
                \\pub const impl: BenchImplementation = .{s};
                \\
            , .{@tagName(bench_implementation)}) catch unreachable;
        },
        else => {
            zig_bench_impl_options.contents.writer().print(
                \\pub const impl = @compileError("Not implemented for {s}");
                \\
            , .{@tagName(bench_implementation)}) catch unreachable;
        },
    }

    const c_bench_impl_leo = b.addStaticLibrary("benchmark-impl-c", "benchmark/rpmalloc-benchmark/benchmark/rpmalloc/benchmark.c");
    c_bench_impl_leo.setBuildMode(mode);
    c_bench_impl_leo.setTarget(target);
    c_bench_impl_leo.strip = strip;
    c_bench_impl_leo.want_lto = want_lto;
    c_bench_impl_leo.single_threaded = single_threaded;
    c_bench_impl_leo.addIncludePath("benchmark/rpmalloc-benchmark/benchmark");
    c_bench_impl_leo.addIncludePath("benchmark/rpmalloc-benchmark/test");
    c_bench_impl_leo.addCSourceFiles(&.{
        "benchmark/rpmalloc-benchmark/benchmark/rpmalloc/rpmalloc.c",
    }, &.{"-O3"});
    c_bench_impl_leo.linkLibC();

    const bench_leo = b.addExecutable(switch (bench_implementation) {
        inline else => |tag| "benchmark-" ++ @tagName(tag),
    }, "benchmark/rpmalloc-benchmark/benchmark/main.c");
    bench_leo.setBuildMode(mode);
    bench_leo.setTarget(target);
    bench_leo.strip = strip;
    bench_leo.want_lto = want_lto;
    bench_leo.single_threaded = single_threaded;

    bench_leo.linkLibC();
    bench_leo.addIncludePath("benchmark/rpmalloc-benchmark/benchmark");
    bench_leo.addIncludePath("benchmark/rpmalloc-benchmark/test");
    bench_leo.addCSourceFiles(&.{
        "benchmark/rpmalloc-benchmark/test/thread.c",
        "benchmark/rpmalloc-benchmark/test/timer.c",
    }, &.{"-O3"});

    switch (bench_implementation) {
        .original => bench_leo.linkLibrary(c_bench_impl_leo),
        .port,
        .gpa,
        => bench_leo.linkLibrary(zig_bench_impl_leo),
    }
    bench_leo.install();

    const bench_run = bench_leo.run();
    bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_run.addArgs(args);
    }
    bench_run.expected_exit_code = null;

    const bench_run_step = b.step("bench", "Run the benchmark");
    bench_run_step.dependOn(&bench_run.step);
}

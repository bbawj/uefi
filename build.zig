const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = std.Target.Cpu.Arch.aarch64,
        .os_tag = std.Target.Os.Tag.uefi,
        .abi = std.Target.Abi.msvc,
    });

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bootaa64",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const installDir = std.Build.Step.InstallArtifact.Options.Dir{ .override = std.Build.InstallDir{ .custom = "../out/efi/boot" } };
    const build_step = b.addInstallArtifact(exe, std.Build.Step.InstallArtifact.Options{ .dest_dir = installDir });
    b.getInstallStep().dependOn(&build_step.step);

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "qemu-system-aarch64",
        "-bios",
        "u-boot.bin",
        // "-drive",
        // "if=none,id=code,format=raw,file=/home/bawj/tools/edk2/Build/ArmVirtQemu-AARCH64/DEBUG_GCC5/FV/QEMU_EFI-pflash.raw,readonly=on",
        // "-drive",
        // "if=none,id=vars,format=raw,file=/home/bawj/tools/edk2/Build/ArmVirtQemu-AARCH64/DEBUG_GCC5/FV/QEMU_VARS-pflash.raw,snapshot=on",
        "-drive",
        "format=raw,file=fat:rw:out",
        "-machine",
        "virt",
        // "-dtb",
        // "dumpdtb=qemu.dtb",
        // "virt,pflash0=code,pflash1=vars",
        "-cpu",
        "max",
        "-serial",
        "stdio",
        "-device",
        "VGA",
        "-device",
        "virtio-rng-pci",
        "-net",
        "none",
    });
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

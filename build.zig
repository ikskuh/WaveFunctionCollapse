const std = @import("std");

const ZeroSdk = @import("vendor/zero-graphics/Sdk.zig");

const pkgs = struct {
    const s2s = std.build.Pkg{
        .name = "s2s",
        .path = .{ .path = "vendor/s2s/s2s.zig" },
    };
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const sdk = ZeroSdk.init(b, false);

    const app = sdk.createApplication("wfc_edit", "src/main.zig");
    app.setBuildMode(mode);
    app.addPackage(pkgs.s2s);

    const desktop_app = app.compileFor(.{ .desktop = target });

    desktop_app.install();

    const run_desktop = desktop_app.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_desktop.step);
}

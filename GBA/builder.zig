const ArrayList = std.ArrayList;
const CrossTarget = std.zig.CrossTarget;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ImageConverter = @import("assetconverter/image_converter.zig").ImageConverter;
const Step = std.build.Step;
const builtin = std.builtin;
const fmt = std.fmt;
const fs = std.fs;
const std = @import("std");

pub const ImageSourceTarget = @import("assetconverter/image_converter.zig").ImageSourceTarget;

const GBALinkerScript = libRoot() ++ "/gba.ld";
const GBALibFile = libRoot() ++ "/gba.zig";

var IsDebugOption: ?bool = null;
var UseGDBOption: ?bool = null;

const gba_thumb_target = blk: {
    var target = CrossTarget{
        .cpu_arch = std.Target.Cpu.Arch.thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
        .os_tag = .freestanding,
    };
    target.cpu_features_add.addFeature(@enumToInt(std.Target.arm.Feature.thumb_mode));
    break :blk target;
};

fn libRoot() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn addGBAStaticLibrary(b: *std.Build, libraryName: []const u8, sourceFile: []const u8, isDebug: bool) *std.build.CompileStep {
    const lib = b.addStaticLibrary(.{
        .name = libraryName,
        .root_source_file = .{ .path = sourceFile },
        .target = gba_thumb_target,
        .optimize = if (isDebug) .Debug else .ReleaseFast,
    });

    lib.setLinkerScriptPath(std.build.FileSource{ .path = GBALinkerScript });

    return lib;
}

pub fn createGBALib(b: *std.Build, isDebug: bool) *std.build.CompileStep {
    return addGBAStaticLibrary(b, "ZigGBA", GBALibFile, isDebug);
}

pub fn addGBAExecutable(b: *std.Build, romName: []const u8, sourceFile: []const u8) *std.build.CompileStep {
    const isDebug = blk: {
        if (IsDebugOption) |value| {
            break :blk value;
        } else {
            const newIsDebug = b.option(bool, "debug", "Generate a debug build") orelse false;
            IsDebugOption = newIsDebug;
            break :blk newIsDebug;
        }
    };

    const useGDB = blk: {
        if (UseGDBOption) |value| {
            break :blk value;
        } else {
            const gdb = b.option(bool, "gdb", "Generate a ELF file for easier debugging with mGBA remote GDB support") orelse false;
            UseGDBOption = gdb;
            break :blk gdb;
        }
    };

    const exe = b.addExecutable(.{
        .name = romName,
        .root_source_file = .{ .path = sourceFile },
        .target = gba_thumb_target,
        .optimize = if (isDebug) .Debug else .ReleaseFast,
    });

    exe.setLinkerScriptPath(std.build.FileSource{ .path = GBALinkerScript });
    if (useGDB) {
        exe.install();
    } else {
        _ = exe.installRaw(b.fmt("{s}.gba", .{romName}), .{});
    }

    const gbaLib = createGBALib(b, isDebug);
    exe.addAnonymousModule("gba", .{ .source_file = .{ .path = GBALibFile } });
    exe.linkLibrary(gbaLib);

    b.default_step.dependOn(&exe.step);

    return exe;
}

const Mode4ConvertStep = struct {
    step: Step,
    builder: *std.Build,
    images: []const ImageSourceTarget,
    targetPalettePath: []const u8,

    pub fn init(b: *std.Build, images: []const ImageSourceTarget, targetPalettePath: []const u8) Mode4ConvertStep {
        return Mode4ConvertStep{
            .builder = b,
            .step = Step.init(.custom, b.fmt("ConvertMode4Image {s}", .{targetPalettePath}), b.allocator, make),
            .images = images,
            .targetPalettePath = targetPalettePath,
        };
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(Mode4ConvertStep, "step", step);
        const ImageSourceTargetList = ArrayList(ImageSourceTarget);

        var fullImages = ImageSourceTargetList.init(self.builder.allocator);
        defer fullImages.deinit();

        for (self.images) |imageSourceTarget| {
            try fullImages.append(ImageSourceTarget{
                .source = self.builder.pathFromRoot(imageSourceTarget.source),
                .target = self.builder.pathFromRoot(imageSourceTarget.target),
            });
        }
        const fullTargetPalettePath = self.builder.pathFromRoot(self.targetPalettePath);

        try ImageConverter.convertMode4Image(self.builder.allocator, fullImages.items, fullTargetPalettePath);
    }
};

pub fn convertMode4Images(libExe: *std.build.CompileStep, images: []const ImageSourceTarget, targetPalettePath: []const u8) void {
    const convertImageStep = libExe.builder.allocator.create(Mode4ConvertStep) catch unreachable;
    convertImageStep.* = Mode4ConvertStep.init(libExe.builder, images, targetPalettePath);
    libExe.step.dependOn(&convertImageStep.step);
}

const std = @import("std");
const unicode = std.unicode;
const uefi = std.os.uefi;
const fmt = std.fmt;
const bmp = @import("bmp.zig");
const font = @import("font.zig");
const builtin = @import("builtin");

// Assigned in main().
var con_out: *uefi.protocol.SimpleTextOutput = undefined;
var counter: u32 = 0;
var resolution_x: usize = undefined;
var resolution_y: usize = undefined;
var cursor_x: usize = undefined;
var cursor_y: usize = undefined;

var volume: *uefi.protocol.File = undefined;

// We need to print each character in an [_]u8 individually because EFI
// encodes strings as UCS-2.
fn puts(msg: []const u8) void {
    for (msg) |c| {
        const c_ = [2]u16{ c, 0 };
        _ = con_out.outputString(@ptrCast(&c_));
    }
}

var print_buf: [10 * 1024]u8 = undefined;

pub fn print(comptime format: []const u8, args: anytype) void {
    if (builtin.os.tag == .uefi) {
        if (fmt.bufPrint(&print_buf, format, args)) |written| {
            puts(written);
        } else |_| {
            puts("could not fit in print buffer\r\n");
        }
    } else {
        std.debug.print(format, args);
    }
}

var graphics_output_protocol: ?*uefi.protocol.GraphicsOutput = undefined;
pub fn main() void {
    con_out = uefi.system_table.con_out.?;
    puts("testing");
    const boot_services = uefi.system_table.boot_services.?;
    var status: uefi.Status = uefi.Status.Success;
    _ = boot_services.setWatchdogTimer(0, 0x1FFFF, 0, null);

    _ = con_out.reset(false);

    // Graphics output?
    status = boot_services.locateProtocol(&uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&graphics_output_protocol));
    if (status != uefi.Status.Success) {
        print("*** graphics output protocol not supported because {}!\r\n", .{status});
        return;
    }
    // Check supported resolutions:
    {
        var i: u32 = 0;
        var info: *uefi.protocol.GraphicsOutput.Mode.Info = undefined;
        var info_size: usize = undefined;
        while (i < graphics_output_protocol.?.mode.max_mode) : (i += 1) {
            status = graphics_output_protocol.?.queryMode(i, &info_size, &info);
            if (status != uefi.Status.Success) {
                print("unable to query graphics_output_protocol mode because {}\r\n", .{status});
                continue;
            }
            print("graphics_output_protocol mode {} {}\r\n", .{ info.horizontal_resolution, info.vertical_resolution });
            if (info.horizontal_resolution == 1920 and info.vertical_resolution == 1080) {
                status = graphics_output_protocol.?.setMode(i);
                if (status != uefi.Status.Success) {
                    print("unable to set graphics_output_protocol mode because {}\r\n", .{status});
                }
                break;
            }
        }
        status = graphics_output_protocol.?.queryMode(graphics_output_protocol.?.mode.mode, &info_size, &info);
        if (status != uefi.Status.Success) {
            print("unable to query the current graphics_output_protocol mode because {}, exiting...\r\n", .{status});
            return;
        }
        resolution_x = info.horizontal_resolution;
        resolution_y = info.vertical_resolution;
    }

    var fs: ?*uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&fs));
    if (status != uefi.Status.Success) {
        print("*** file system protocol not supported because {}!\r\n", .{status});
        return;
    }
    status = fs.?.openVolume(&volume);
    if (status != uefi.Status.Success) {
        print("open volume failed because {}", .{status});
        return;
    }

    const wallpaper_size: usize = 7 * 1024 * 1024;
    const wallpaper: []u8 = uefi.pool_allocator.alloc(u8, wallpaper_size) catch |err| {
        print("failed to alloc wallpaper buffer because {}", .{err});
        return;
    };
    defer uefi.pool_allocator.free(wallpaper);

    _ = open_file(wallpaper, "efi\\boot\\wallpaper.bmp") catch |err| {
        print("failed to open wallpaper image because {}", .{err});
        return;
    };
    const wp = bmp.parse(uefi.pool_allocator, wallpaper[0..wallpaper_size]) catch |err| {
        print("failed to load image because {}", .{err});
        return;
    };
    print("image pixels {} height {} width {}\r\n", .{ wp.pixels.len, wp.height, wp.width });
    const blt_buffer = uefi.pool_allocator.alloc(uefi.protocol.GraphicsOutput.BltPixel, resolution_x * resolution_y) catch |err| {
        print("failed to alloc blt buffer because {}", .{err});
        return;
    };
    @memset(blt_buffer, uefi.protocol.GraphicsOutput.BltPixel{ .red = 255, .green = 255, .blue = 255 });
    // scale_nearest_neighbour(wp, &blt_buffer, resolution_x, resolution_y);
    const ttf: []u8 = uefi.pool_allocator.alloc(u8, 20 * 1024 * 1024) catch |err| {
        print("failed to alloc ttf buffer because {}", .{err});
        return;
    };
    defer uefi.pool_allocator.free(ttf);
    const ttf_size = open_file(ttf, "efi\\boot\\SF-Pro.ttf") catch |err| {
        print("failed to open font file because {}", .{err});
        return;
    };
    font.ttf_load(uefi.pool_allocator, ttf[0..ttf_size]) catch |err| {
        print("failed to load font file because {}", .{err});
        return;
    };
    defer font.ttf_unload(uefi.pool_allocator);
    status = graphics_output_protocol.?.blt(blt_buffer.ptr, uefi.protocol.GraphicsOutput.BltOperation.BltBufferToVideo, 0, 0, 0, 0, resolution_x, resolution_y, 0);
    if (status != uefi.Status.Success) {
        print("blt failed because {}", .{status});
        return;
    }
    const draw_buffer = DrawBuffer{ .pixels = blt_buffer, .width = resolution_x, .height = resolution_y };
    font.draw("ABCDEFGHIJKLMNOPQRSTUVWXYZ", draw_buffer);

    // Create an array of input events.
    const input_events = [_]uefi.Event{
        uefi.system_table.con_in.?.wait_for_key,
    };
    // TODO add more input events

    var index: usize = undefined;
    // Wait for input events.
    while (boot_services.waitForEvent(input_events.len, &input_events, &index) == uefi.Status.Success) {
        // index tells us which event has been signalled.

        // Key event
        if (index == 0) {
            var input_key: uefi.protocol.SimpleTextInput.Key.Input = undefined;
            if (uefi.system_table.con_in.?.readKeyStroke(&input_key) == uefi.Status.Success) {
                switch (input_key.scan_code) {
                    1 => {
                        draw_buffer.reset();
                        font.draw("B", draw_buffer);
                    },
                    else => {},
                }
            }
        }
    }
}

const FileError = error{
    OpenError,
    ReadError,
};

fn open_file(read_buf: []u8, path: []const u8) !usize {
    var f: *uefi.protocol.File = undefined;
    const efi_path = try unicode.utf8ToUtf16LeAllocZ(uefi.pool_allocator, path);
    defer uefi.pool_allocator.free(efi_path);
    var status = volume.open(&f, efi_path.ptr, uefi.protocol.File.efi_file_mode_read, uefi.protocol.File.efi_file_valid_attr);
    if (status != uefi.Status.Success) {
        return FileError.OpenError;
    }
    var size = read_buf.len;
    status = f.read(&size, read_buf.ptr);
    if (status != uefi.Status.Success) {
        return FileError.ReadError;
    }
    print("size of file {}\r\n", .{size});
    return size;
}

pub fn scale_nearest_neighbour(image: bmp.Image, target_buf: *[]uefi.protocol.GraphicsOutput.BltPixel, target_x: usize, target_y: usize) void {
    const width = @as(f32, @floatFromInt(image.width));
    const height = @as(f32, @floatFromInt(image.height));
    const y_scale: f32 = @as(f32, @floatFromInt(target_y)) / height;
    const x_scale: f32 = @as(f32, @floatFromInt(target_x)) / width;

    for (0..target_y) |y| {
        for (0..target_x) |x| {
            const src_y: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * y_scale));
            const src_x: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * x_scale));
            const nn = image.pixels[src_y * image.width + src_x];
            target_buf.*[y * target_x + x].red = nn.r;
            target_buf.*[y * target_x + x].green = nn.g;
            target_buf.*[y * target_x + x].blue = nn.b;
        }
    }
}

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const DrawBuffer = struct {
    height: usize,
    width: usize,
    pixels: []uefi.protocol.GraphicsOutput.BltPixel,

    pub fn put_pixel(self: DrawBuffer, x: u16, y: u16, color: Color) void {
        if (y >= self.height or x >= self.width) return;
        self.pixels[y * self.width + x].red = color.r;
        self.pixels[y * self.width + x].green = color.g;
        self.pixels[y * self.width + x].blue = color.b;
    }

    pub fn blit(self: DrawBuffer) void {
        const status = graphics_output_protocol.?.blt(self.pixels.ptr, uefi.protocol.GraphicsOutput.BltOperation.BltBufferToVideo, 0, 0, 0, 0, resolution_x, resolution_y, 0);
        if (status != uefi.Status.Success) {
            print("blt failed because {}", .{status});
            return;
        }
    }

    pub fn reset(self: DrawBuffer) void {
        @memset(self.pixels, uefi.protocol.GraphicsOutput.BltPixel{ .red = 255, .green = 255, .blue = 255 });
    }
};

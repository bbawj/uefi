const unicode = @import("std").unicode;
const uefi = @import("std").os.uefi;
const fmt = @import("std").fmt;
const bmp = @import("bmp.zig");

// Assigned in main().
var con_out: *uefi.protocol.SimpleTextOutput = undefined;
var counter: u32 = 0;
var resolution_x: usize = undefined;
var resolution_y: usize = undefined;
var cursor_x: usize = undefined;
var cursor_y: usize = undefined;

// We need to print each character in an [_]u8 individually because EFI
// encodes strings as UCS-2.
fn puts(msg: []const u8) void {
    for (msg) |c| {
        const c_ = [2]u16{ c, 0 };
        _ = con_out.outputString(@ptrCast(&c_));
    }
}

fn printf(buf: []u8, comptime format: []const u8, args: anytype) void {
    puts(fmt.bufPrint(buf, format, args) catch unreachable);
}

fn count(event: uefi.Event, context: ?*anyopaque) callconv(.C) void {
    counter += 1;
    _ = event;
    _ = context;
    _ = con_out.setCursorPosition(0, 1);
    var buf: [64]u8 = undefined;
    printf(buf[0..], "count() has been called {} times.", .{counter});
}

pub fn main() void {
    con_out = uefi.system_table.con_out.?;
    puts("testing");
    const boot_services = uefi.system_table.boot_services.?;
    var status: uefi.Status = uefi.Status.Success;
    _ = boot_services.setWatchdogTimer(0, 0x1FFFF, 0, null);

    _ = con_out.reset(false);

    // Graphics output?
    var buf: [256]u8 = undefined;
    var graphics_output_protocol: ?*uefi.protocol.GraphicsOutput = undefined;
    status = boot_services.locateProtocol(&uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&graphics_output_protocol));
    if (status != uefi.Status.Success) {
        printf(buf[0..], "*** graphics output protocol not supported because {}!\r\n", .{status});
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
                printf(buf[0..], "unable to query graphics_output_protocol mode because {}\r\n", .{status});
                continue;
            }
            printf(buf[0..], "graphics_output_protocol mode {} {}\r\n", .{ info.horizontal_resolution, info.vertical_resolution });
            if (info.horizontal_resolution == 1920 and info.vertical_resolution == 1080) {
                status = graphics_output_protocol.?.setMode(i);
                if (status != uefi.Status.Success) {
                    printf(buf[0..], "unable to set graphics_output_protocol mode because {}\r\n", .{status});
                }
                break;
            }
        }
        status = graphics_output_protocol.?.queryMode(graphics_output_protocol.?.mode.mode, &info_size, &info);
        if (status != uefi.Status.Success) {
            printf(buf[0..], "unable to query the current graphics_output_protocol mode because {}, exiting...\r\n", .{status});
            return;
        }
        resolution_x = info.horizontal_resolution;
        resolution_y = info.vertical_resolution;
    }

    var fs: ?*uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&fs));
    if (status != uefi.Status.Success) {
        printf(buf[0..], "*** file system protocol not supported because {}!\r\n", .{status});
        return;
    }
    var f: *uefi.protocol.File = undefined;
    status = fs.?.openVolume(&f);
    if (status != uefi.Status.Success) {
        printf(buf[0..], "open volume failed because {}", .{status});
        return;
    }
    var wallpaper: *uefi.protocol.File = undefined;
    status = f.open(&wallpaper, unicode.utf8ToUtf16LeStringLiteral("efi\\boot\\wallpaper.bmp"), uefi.protocol.File.efi_file_mode_read, uefi.protocol.File.efi_file_valid_attr);
    if (status != uefi.Status.Success) {
        printf(buf[0..], "failed to open wallpaper because {}", .{status});
        return;
    }
    const wallpaper_buf_size: usize = 7 * 1024 * 1024;
    const wallpaper_buf: []u8 = uefi.pool_allocator.alloc(u8, wallpaper_buf_size) catch |err| {
        printf(buf[0..], "failed to alloc wallpaper buffer because {}", .{err});
        return;
    };
    var size = wallpaper_buf_size;
    printf(buf[0..], "size of buffer {} \r\n", .{wallpaper_buf.len});
    status = wallpaper.read(&size, wallpaper_buf.ptr);
    if (status != uefi.Status.Success) {
        printf(buf[0..], "failed to read wallpaper because {}", .{status});
        return;
    }
    printf(buf[0..], "size of wallpaper {} size of buffer {}\r\n", .{ size, wallpaper_buf.len });
    const wp = bmp.parse(uefi.pool_allocator, wallpaper_buf[0..size]) catch |err| {
        printf(buf[0..], "failed to load image because {}", .{err});
        return;
    };
    printf(buf[0..], "image pixels {} height {} width {}\r\n", .{ wp.pixels.len, wp.height, wp.width });
    var blt_buffer = uefi.pool_allocator.alloc(uefi.protocol.GraphicsOutput.BltPixel, resolution_x * resolution_y) catch |err| {
        printf(buf[0..], "failed to alloc blt buffer because {}", .{err});
        return;
    };
    scale_nearest_neighbour(wp, &blt_buffer, resolution_x, resolution_y);
    status = graphics_output_protocol.?.blt(blt_buffer.ptr, uefi.protocol.GraphicsOutput.BltOperation.BltBufferToVideo, 0, 0, 0, 0, resolution_x, resolution_y, 0);
    if (status != uefi.Status.Success) {
        printf(buf[0..], "blt failed because {}", .{status});
        return;
    }
    while (true) {}
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

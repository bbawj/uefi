const std = @import("std");
const mem = @import("std").mem;
const assert = @import("std").debug.assert;

const BM_header = packed struct {
    id: u16,
    file_size: u32,
    _reserved0: u16,
    _reserved1: u16,
    pixel_offset: u32,
};

const Core_Header = packed struct {
    header_size: u32,
    width: u32,
    height: u32,
    color_planes: u16,
    bits_per_pixel: u16,
};

const Info_Header = packed struct {
    compression: u32,
    raw_size: u32,
    resolution_x: u32,
    resolution_y: u32,
    n_colors: u32,
    n_impt_colors: u32,
};

pub const Pixel = struct {
    b: u8,
    g: u8,
    r: u8,
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []Pixel,
};

pub const BMPError = error{
    InvalidBMPFile,
    UnsupportedCompression,
};

pub fn parse(allocator: mem.Allocator, bytes: []u8) !Image {
    const bm_header: *align(1) BM_header = @alignCast(@ptrCast(bytes.ptr));
    if (bm_header.id != 0x4d42) {
        return BMPError.InvalidBMPFile;
    }
    const core_header: *align(1) Core_Header = @alignCast(@ptrCast(bytes[14..].ptr));
    const info_header: *align(1) Info_Header = @alignCast(@ptrCast(bytes[30..].ptr));
    if (info_header.compression != 0) {
        return BMPError.UnsupportedCompression;
    }

    const pixel_data: []u8 = bytes[bm_header.pixel_offset .. bm_header.pixel_offset + info_header.raw_size];
    const bytes_per_row: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(core_header.bits_per_pixel)) * @as(f64, @floatFromInt(core_header.width)) / @as(f64, 32)) * 4);
    assert(bytes_per_row * core_header.height == info_header.raw_size);
    const pixel_row_size = core_header.bits_per_pixel * core_header.width / 8;

    var results = try allocator.alloc(Pixel, core_header.height * core_header.width);

    for (0..core_header.height) |y| {
        const pixel_index = y * bytes_per_row;
        const row = pixel_data[pixel_index..(pixel_index + pixel_row_size)];
        for (0..core_header.width) |x| {
            const r = row[x * 3 + 2];
            const g = row[x * 3 + 1];
            const b = row[x * 3 + 0];
            const idx = (core_header.height - 1 - y) * core_header.width + x;
            results[idx].r = r;
            results[idx].g = g;
            results[idx].b = b;
        }
    }
    return Image{
        .width = core_header.width,
        .height = core_header.height,
        .pixels = results,
    };
}

test "bmp" {
    const cwd = std.fs.cwd();
    const f = try cwd.openFile("out/efi/boot/wallpaper.bmp", std.fs.File.OpenFlags{});
    var buf: [1024 * 1024 * 10]u8 = undefined;
    const size = try f.readAll(&buf);
    const image = try parse(std.testing.allocator, buf[0..size]);
    std.debug.print("pixels size: {}\n", .{image.pixels[1920 * 1080 - 1]});
    // std.testing.allocator.destroy(pixels.ptr);
}

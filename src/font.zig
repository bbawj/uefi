const std = @import("std");
const assert = @import("std").debug.assert;
const print = @import("main.zig").print;
const Endian = @import("std").builtin.Endian;
const Allocator = @import("std").mem.Allocator;
const DrawBuffer = @import("main.zig").DrawBuffer;
const Color = @import("main.zig").Color;
const builtin = @import("builtin");
const dbg = builtin.mode == builtin.Mode.Debug;

const TableRecord = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

var HEAD: Head = undefined;
var MAXP: Maxp = undefined;
var records: []TableRecord = undefined;
var glyphs: []Glyph = undefined;
var locs: []u32 = undefined;

pub fn ttf_load(allocator: Allocator, bytes: []const u8) !void {
    const num_tables = std.mem.readInt(u16, bytes[4..6], Endian.big);
    print("num tables: {}\n", .{num_tables});
    const table_records = bytes[12..(12 + @sizeOf(TableRecord) * num_tables)];

    records = try allocator.alloc(TableRecord, num_tables);

    for (0..num_tables) |i| {
        const off = i * 16;
        @memcpy(&records[i].tag, table_records[off..(off + 4)]);
        records[i].checksum = std.mem.readInt(u32, table_records[(off + 4)..(off + 8)][0..4], Endian.big);
        records[i].offset = std.mem.readInt(u32, table_records[(off + 8)..(off + 12)][0..4], Endian.big);
        records[i].length = std.mem.readInt(u32, table_records[(off + 12)..(off + 16)][0..4], Endian.big);
        print("record {s} offset: {}\n", .{ records[i].tag, records[i].offset });
        if (std.mem.eql(u8, "head", &records[i].tag)) {
            HEAD = std.mem.bytesAsValue(Head, @constCast(bytes[records[i].offset .. records[i].offset + records[i].length].ptr)).*;
            std.mem.byteSwapAllFields(Head, @alignCast(&HEAD));
            assert(HEAD.magic == 0x5F0F3CF5);
            print("head: {}\n", .{HEAD});
        } else if (std.mem.eql(u8, "maxp", &records[i].tag)) {
            MAXP = std.mem.bytesAsValue(Maxp, @constCast(bytes[records[i].offset .. records[i].offset + records[i].length].ptr)).*;
            std.mem.byteSwapAllFields(Maxp, @alignCast(&MAXP));
            print("maxp: {}\n", .{MAXP});
        }
    }
    locs = try allocator.alloc(u32, MAXP.num_glyphs);
    try loca(HEAD.index_to_loc_format, bytes[find_record(num_tables, "loca").?.offset..]);
    print("locs length: {}\n", .{locs.len});
    glyphs = try allocator.alloc(Glyph, MAXP.num_glyphs);
    try glyf(allocator, bytes[find_record(num_tables, "glyf").?.offset..]);
}

pub fn ttf_unload(allocator: Allocator) void {
    for (0..glyphs.len) |i| {
        switch (glyphs[i].data) {
            .simple => {
                allocator.free(glyphs[i].data.simple.coords);
                allocator.free(glyphs[i].data.simple.end_pts_of_contour);
                allocator.free(glyphs[i].data.simple.flags);
            },
            .compound => {
                // TODO: free compound glyphs
            },
        }
    }
    allocator.free(locs);
    allocator.free(records);
    allocator.free(glyphs);
}

pub fn draw(target_buf: DrawBuffer) void {
    const g = glyphs[0];
    const font_size = 12;
    const ppi = 227;
    const ppem = font_size * ppi / 72;

    switch (g.data) {
        .simple => |d| {
            for (1..d.coords.len) |c| {
                const p1 = d.coords[c - 1];
                const p2 = d.coords[c];

                const from_x = @as(u32, @intCast(p1.x)) * ppem / HEAD.units_per_em;
                const from_y = @as(u32, @intCast(p1.y)) * ppem / HEAD.units_per_em;
                const to_x = @as(u32, @intCast(p2.x)) * ppem / HEAD.units_per_em;
                const to_y = @as(u32, @intCast(p2.y)) * ppem / HEAD.units_per_em;
                print("going from {},{} to {},{}\r\n", .{ from_x, from_y, to_x, to_y });
                const dx: i64 = @as(i64, @intCast(to_x)) - @as(i64, @intCast(from_x));
                const dy: i64 = @as(i64, @intCast(to_y)) - @as(i64, @intCast(from_y));
                const pixel_dx: i8 = if (dx > 0) 1 else -1;
                const pixel_dy: i8 = if (dy > 0) 1 else -1;
                var D: i64 = 2 * dy - dx;
                var cursor_x: i64 = from_x;
                var cursor_y: i64 = from_y;
                if (@abs(dx) >= @abs(dy)) {
                    while (cursor_x != to_x) {
                        target_buf.blit(@intCast(cursor_x), @intCast(cursor_y), Color{ .r = 255, .g = 0, .b = 0 });
                        cursor_x += pixel_dx;
                        if (cursor_y != to_y) {
                            if (D > 0) {
                                cursor_y += pixel_dy;
                                D += 2 * dy - 2 * dx;
                            } else {
                                D += 2 * dy;
                            }
                        }
                    }
                } else {
                    while (cursor_y != to_y) {
                        target_buf.blit(@intCast(cursor_x), @intCast(cursor_y), Color{ .r = 255, .g = 0, .b = 0 });
                        cursor_y += pixel_dy;
                        if (cursor_x != to_x) {
                            if (D > 0) {
                                cursor_x += pixel_dx;
                                D += 2 * dy - 2 * dx;
                            } else {
                                D += 2 * dy;
                            }
                        }
                    }
                }
            }
        },
        .compound => {},
    }
}

fn find_record(num_tables: usize, tag: []const u8) ?TableRecord {
    for (0..num_tables) |i| {
        const record = records[i];
        if (std.mem.eql(u8, tag, &record.tag)) {
            return record;
        }
    }
    return null;
}

fn loca(format: i16, bytes: []const u8) !void {
    if (format == 0) {
        // missing character glyph at 0
        for (0..MAXP.num_glyphs) |i| {
            locs[i] = 2 * std.mem.readInt(u16, bytes[i * @sizeOf(u16) .. (i + 1) * @sizeOf(u16)][0..2], Endian.big);
        }
    } else if (format == 1) {
        // missing character glyph at 0
        for (0..MAXP.num_glyphs) |i| {
            locs[i] = std.mem.readInt(u32, bytes[i * @sizeOf(u32) .. (i + 1) * @sizeOf(u32)][0..4], Endian.big);
        }
    } else {
        @panic("invalid loca format");
    }
}

const GlyphDataKind = enum(u8) {
    simple,
    compound,
};

const SimpleData = struct {
    end_pts_of_contour: []u16,
    flags: []u8,
    coords: []Coord,
};

const Coord = struct {
    x: u16,
    y: u16,
};

const GlyphData = union(GlyphDataKind) {
    simple: SimpleData,
    compound: struct {},
};
const Glyph = struct {
    num_contours: i16 align(1),
    x_min: i16 align(1),
    y_min: i16 align(1),
    x_max: i16 align(1),
    y_max: i16 align(1),
    data: GlyphData,
};

fn glyf(allocator: Allocator, bytes: []const u8) !void {
    for (0..locs.len) |i| {
        var byte_ptr = bytes[locs[i]..].ptr;
        var g = &glyphs[i];
        g.num_contours = std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
        g.x_min = std.mem.readInt(i16, byte_ptr[2..4], Endian.big);
        g.y_min = std.mem.readInt(i16, byte_ptr[4..6], Endian.big);
        g.x_max = std.mem.readInt(i16, byte_ptr[6..8], Endian.big);
        g.y_max = std.mem.readInt(i16, byte_ptr[8..10], Endian.big);
        // print("{}\r\n", .{g});
        byte_ptr += 10;
        if (g.num_contours < 0) {
            // TODO: handle compound glyphs
            g.data = GlyphData{ .compound = undefined };
            continue;
        } else {
            var data = GlyphData{ .simple = SimpleData{
                .end_pts_of_contour = undefined,
                .flags = undefined,
                .coords = undefined,
            } };
            var end_pts_of_contour = try allocator.alloc(u16, @intCast(g.num_contours));
            data.simple.end_pts_of_contour = end_pts_of_contour;
            for (0..@intCast(g.num_contours)) |j| {
                end_pts_of_contour[j] = std.mem.readInt(u16, byte_ptr[0..2], Endian.big);
                byte_ptr += 2;
            }
            // skip past instructions
            byte_ptr += 2 + std.mem.readInt(u16, byte_ptr[0..2], Endian.big);
            const num_points = end_pts_of_contour[end_pts_of_contour.len - 1] + 1;
            var flags = try allocator.alloc(u8, @intCast(num_points));
            data.simple.flags = flags;

            const x_short_mask = 1;
            const y_short_mask = 2;
            const repeat_mask = 3;
            const x_same_mask = 4;
            const y_same_mask = 5;

            var repeat: u8 = 0;
            for (0..num_points) |j| {
                if (repeat > 0) {
                    flags[j] = flags[j - 1];
                    repeat -= 1;
                    continue;
                }

                flags[j] = byte_ptr[0];
                byte_ptr += 1;
                if (isBitSet(flags[j], repeat_mask)) {
                    repeat = byte_ptr[0];
                    byte_ptr += 1;
                }
            }

            var coords = try allocator.alloc(Coord, @intCast(num_points));
            data.simple.coords = coords;
            for (0..num_points) |j| {
                const flag = flags[j];
                var x: i16 = 0;
                if (j != 0) {
                    x = @intCast(coords[j - 1].x);
                }

                if (isBitSet(flag, x_short_mask)) {
                    if (isBitSet(flag, x_same_mask)) {
                        x += byte_ptr[0];
                    } else {
                        x -= byte_ptr[0];
                    }
                    byte_ptr += 1;
                } else {
                    if (!isBitSet(flag, x_same_mask)) {
                        x += std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
                        byte_ptr += 2;
                    }
                }
                // scale x to start from 0
                if (j == 0)
                    x -= g.x_min;
                coords[j].x = @intCast(x);
            }

            for (0..num_points) |j| {
                const flag = flags[j];
                // This first coordinate is not flipped or scaled, perform as per ttf spec
                if (j == 0) {
                    var y: i16 = 0;
                    if (isBitSet(flag, y_short_mask)) {
                        if (isBitSet(flag, y_same_mask)) {
                            y += byte_ptr[0];
                        } else {
                            y -= byte_ptr[0];
                        }
                        byte_ptr += 1;
                    } else {
                        if (!isBitSet(flag, y_same_mask)) {
                            y += std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
                            byte_ptr += 2;
                        }
                    }
                    // scale y to positive
                    y -= g.y_min;
                    // flip y since in our coordinate system y increases downwards
                    y = -y + (g.y_max - g.y_min);
                    coords[j].y = @intCast(y);
                } else {
                    // all coordinates are relative from the first one
                    // deltas are now flipped
                    var y = coords[j - 1].y;
                    if (isBitSet(flag, y_short_mask)) {
                        if (isBitSet(flag, y_same_mask)) {
                            y -= byte_ptr[0];
                        } else {
                            y += byte_ptr[0];
                        }
                        byte_ptr += 1;
                    } else {
                        if (!isBitSet(flag, y_same_mask)) {
                            const delta = std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
                            if (delta > 0) {
                                y += @intCast(delta);
                            } else {
                                y += @intCast(-delta);
                            }
                            byte_ptr += 2;
                        }
                    }
                    coords[j].y = y;
                }
            }
            g.data = data;
        }
        if (i == 0) print("glyph: {}\n", .{glyphs[i].data.simple});
    }
}

fn isBitSet(byte: u8, comptime bit: u3) bool {
    return ((byte >> bit) & 1) == 1;
}

const Head = struct {
    version: u32 align(1),
    rev: u32 align(1),
    checksum_adjustment: u32 align(1),
    magic: u32 align(1),
    flags: u16 align(1),
    units_per_em: u16 align(1),
    created: u64 align(1),
    modified: u64 align(1),
    x_min: i16 align(1),
    y_min: i16 align(1),
    x_max: i16 align(1),
    y_max: i16 align(1),
    mac_style: u16 align(1),
    lowest_rec_ppem: u16 align(1),
    font_dir_hint: i16 align(1),
    index_to_loc_format: i16 align(1),
    glyph_data_format: i16 align(1),
};

const Maxp = struct {
    version: u32 align(1),
    num_glyphs: u16 align(1),
};

test {
    const cwd = std.fs.cwd();
    const f = try cwd.openFile("out/efi/boot/SF-Pro.ttf", std.fs.File.OpenFlags{});
    var buf: [1024 * 1024 * 10]u8 = undefined;
    print("size: {}\n", .{@sizeOf(u16)});
    const size = try f.readAll(&buf);
    try ttf_load(std.testing.allocator, buf[0..size]);
    ttf_unload(std.testing.allocator);
}

const std = @import("std");
const assert = @import("std").debug.assert;
const print = @import("std").debug.print;
const Endian = @import("std").builtin.Endian;
const Allocator = @import("std").mem.Allocator;

const TableRecord = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

var HEAD: Head = undefined;
var MAXP: Maxp = undefined;

pub fn ttf_parse(allocator: Allocator, bytes: []const u8) !void {
    const num_tables = std.mem.readInt(u16, bytes[4..6], Endian.big);
    print("num tables: {}\n", .{num_tables});
    const table_records = bytes[12..(12 + @sizeOf(TableRecord) * num_tables)];

    const records = try allocator.alloc(TableRecord, num_tables);
    defer allocator.free(records);

    for (0..num_tables) |i| {
        const off = i * 16;
        @memcpy(&records[i].tag, table_records[off..(off + 4)]);
        records[i].checksum = std.mem.readInt(u32, table_records[(off)..(off + 4)][0..4], Endian.big);
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
    const locs = try loca(allocator, HEAD.index_to_loc_format, bytes[find_record(num_tables, records, "loca").?.offset..]);
    print("locs length: {}\n", .{locs.len});
    const glyphs = try glyf(allocator, bytes[find_record(num_tables, records, "glyf").?.offset..], locs);

    for (0..glyphs.len) |i| {
        switch (glyphs[i].data) {
            .simple => {
                allocator.free(glyphs[i].data.simple.x_coords);
                allocator.free(glyphs[i].data.simple.y_coords);
                allocator.free(glyphs[i].data.simple.end_pts_of_contour);
                allocator.free(glyphs[i].data.simple.flags);
            },
            .compound => {
                // TODO: free compound glyphs
            },
        }
    }
}

fn find_record(num_tables: usize, records: []TableRecord, tag: []const u8) ?TableRecord {
    for (0..num_tables) |i| {
        const record = records[i];
        if (std.mem.eql(u8, tag, &record.tag)) {
            return record;
        }
    }
    return null;
}

fn loca(allocator: Allocator, format: i16, bytes: []const u8) ![]u32 {
    var locs = try allocator.alloc(u32, MAXP.num_glyphs);
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
    return locs;
}

const GlyphDataKind = enum(u8) {
    simple,
    compound,
};

const SimpleData = struct {
    end_pts_of_contour: []u16,
    flags: []u8,
    x_coords: []i16,
    y_coords: []i16,
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

fn glyf(allocator: Allocator, bytes: []const u8, locs: []u32) ![]Glyph {
    var glyphs = try allocator.alloc(Glyph, MAXP.num_glyphs);
    for (0..MAXP.num_glyphs) |i| {
        var byte_ptr = bytes[locs[i]..].ptr;
        var g = &glyphs[i];
        g.num_contours = std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
        g.x_min = std.mem.readInt(i16, byte_ptr[2..4], Endian.big);
        g.y_min = std.mem.readInt(i16, byte_ptr[4..6], Endian.big);
        g.x_max = std.mem.readInt(i16, byte_ptr[6..8], Endian.big);
        g.y_max = std.mem.readInt(i16, byte_ptr[8..10], Endian.big);
        byte_ptr += 10;
        if (g.num_contours < 0) {
            // TODO: handle compound glyphs
            g.data = GlyphData{ .compound = undefined };
            continue;
        } else {
            var data = GlyphData{ .simple = SimpleData{
                .end_pts_of_contour = undefined,
                .flags = undefined,
                .x_coords = undefined,
                .y_coords = undefined,
            } };
            var end_pts_of_contour = try allocator.alloc(u16, @intCast(g.num_contours));
            data.simple.end_pts_of_contour = end_pts_of_contour;
            for (0..@intCast(g.num_contours)) |j| {
                end_pts_of_contour[j] = std.mem.readInt(u16, byte_ptr[0..2], Endian.big);
                byte_ptr += @sizeOf(u16);
            }
            // skip past instructions
            byte_ptr += 2 + std.mem.readInt(u16, byte_ptr[0..2], Endian.big);
            const num_points = end_pts_of_contour[end_pts_of_contour.len - 1] + 1;
            var flags = try allocator.alloc(u8, @intCast(num_points));
            data.simple.flags = flags;

            var repeat: u8 = 0;
            const repeat_mask = 8;
            for (0..num_points) |j| {
                if (repeat > 0) {
                    flags[j] = flags[j - 1];
                    repeat -= 1;
                    continue;
                }

                flags[j] = byte_ptr[0];
                byte_ptr += 1;
                if ((flags[j] & repeat_mask) != 0) {
                    repeat = byte_ptr[0];
                    byte_ptr += 1;
                }
            }

            const x_short_mask = 2;
            const y_short_mask = 4;
            const x_same_mask = 16;
            const y_same_mask = 32;
            var x_coords = try allocator.alloc(i16, @intCast(num_points));
            var y_coords = try allocator.alloc(i16, @intCast(num_points));
            data.simple.x_coords = x_coords;
            data.simple.y_coords = y_coords;
            for (0..num_points) |j| {
                const flag = flags[j];
                if (j != 0) {
                    x_coords[j] = x_coords[j - 1];
                } else {
                    x_coords[j] = 0;
                }

                if ((flag & x_short_mask) != 0) {
                    x_coords[j] = byte_ptr[0];
                    if ((flag & x_same_mask) == 0) {
                        x_coords[j] = -x_coords[j];
                    }
                    byte_ptr += 1;
                } else {
                    if ((flag & x_same_mask) == 0) {
                        x_coords[j] += std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
                        byte_ptr += 2;
                    }
                }
            }

            for (0..num_points) |j| {
                const flag = flags[j];
                if (j != 0) {
                    y_coords[j] = y_coords[j - 1];
                } else {
                    y_coords[j] = 0;
                }

                if ((flag & y_short_mask) != 0) {
                    y_coords[j] = byte_ptr[0];
                    if ((flag & y_same_mask) == 0) {
                        y_coords[j] = -y_coords[j];
                    }
                    byte_ptr += 1;
                } else {
                    if ((flag & y_same_mask) == 0) {
                        y_coords[j] += std.mem.readInt(i16, byte_ptr[0..2], Endian.big);
                        byte_ptr += 2;
                    }
                }
            }
            g.data = data;
        }
        if (i == 0) print("glyph: {}\n", .{glyphs[i].data.simple});
    }
    return glyphs;
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
    const size = try f.readAll(&buf);
    try ttf_parse(std.testing.allocator, buf[0..size]);
}

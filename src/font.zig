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
var CMAP: std.hash_map.AutoHashMap(u8, u16) = undefined;

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
    // var cmap = std.hash_map.AutoHashMap(u8, u16);
    CMAP = std.hash_map.AutoHashMap(u8, u16).init(allocator);
    cmap_parse(bytes);
    print("{}\n", .{CMAP.get('H').?});
    locs = try allocator.alloc(u32, MAXP.num_glyphs);
    try loca(HEAD.index_to_loc_format, bytes[find_record("loca").?.offset..]);
    print("locs length: {}\n", .{locs.len});
    glyphs = try allocator.alloc(Glyph, MAXP.num_glyphs);
    try glyf(allocator, bytes[find_record("glyf").?.offset..]);
}

const Reader = struct {
    bytes: []const u8,

    var idx: u32 = 0;

    pub fn curLoc(self: Reader, comptime t: type) [*]t {
        return @ptrCast(@constCast(&self.bytes[idx..]));
    }

    pub fn readSlice(self: Reader, comptime t: type, size: u32) []t {
        const ret = @as([*]t, @alignCast(@ptrCast(@constCast(self.bytes[idx..].ptr))))[0..size];
        self.skipBytes(size * @sizeOf(t));
        return ret;
    }

    pub fn readType(self: Reader, comptime t: type) t {
        const ret = std.mem.readInt(t, self.bytes[idx .. idx + @sizeOf(t)][0..@sizeOf(t)], Endian.big);
        idx += @sizeOf(t);
        return ret;
    }

    pub fn skipBytes(self: Reader, skip: u32) void {
        _ = self;
        idx += skip;
    }

    pub fn seekTo(self: Reader, offset: u32) void {
        _ = self;
        idx = offset;
    }
};

fn cmap_parse(bytes: []const u8) void {
    const cmap = find_record("cmap");
    const reader = Reader{ .bytes = bytes[cmap.?.offset..] };
    assert(reader.readType(u16) == 0);
    const num_subtables = reader.readType(u16);

    // just use the first one, expecting unicode platform
    for (0..num_subtables) |_| {
        const platform_id = reader.readType(u16);
        if (platform_id != 0) {
            reader.skipBytes(@sizeOf(u16) + @sizeOf(u32));
            continue;
        }
        const encoding_id = reader.readType(u16);
        if (encoding_id != 3 and encoding_id != 4) {
            print("encoding: {}\n", .{encoding_id});
            reader.skipBytes(@sizeOf(u32));
            continue;
        }

        // only support Unicode format 12
        const offset = reader.readType(u32);
        reader.seekTo(offset);
        const format = reader.readType(u16);
        print("format: {}\n", .{format});

        switch (format) {
            4 => {
                reader.skipBytes(@sizeOf(u16) * 2);
                const segcount = reader.readType(u16) / 2;
                reader.skipBytes(@sizeOf(u16) * 3);
                const end_codes: []u16 = reader.readSlice(u16, segcount);
                assert(0xFFFF == end_codes[segcount - 1]);
                assert(0 == reader.readType(u16));
                const start_codes = reader.readSlice(u16, segcount);
                const id_deltas = reader.readSlice(u16, segcount);
                const id_range_start = reader.curLoc(u16);
                const id_range = reader.readSlice(u16, segcount);
                // const glyph_ids = reader.curLoc(u16);
                for (0..1 << 7) |code| {
                    for (end_codes, 0..) |end_code, idx| {
                        const end = @byteSwap(end_code);
                        if (end >= code) {
                            const start = @byteSwap(start_codes[idx]);
                            if (start <= code) {
                                const delta = @byteSwap(id_deltas[idx]);
                                const range_offset = @byteSwap(id_range[idx]);
                                if (range_offset == 0) {
                                    const glyph_id = (code + delta) % 0xFFFF;
                                    CMAP.put(@intCast(code), @intCast(glyph_id)) catch unreachable;
                                } else {
                                    const glyph_id = id_range_start[idx + (code - start) + range_offset / 2];
                                    CMAP.put(@intCast(code), @intCast(glyph_id)) catch unreachable;
                                    // assert(false);
                                }
                            } else {
                                // CMAP.put(@intCast(code), 0) catch unreachable;
                                break;
                            }
                        }
                    }
                }
            },
            12 => {
                reader.skipBytes(@sizeOf(u16) + @sizeOf(u32) * 2);
                const num_grps = reader.readType(u32);

                // support only basic ASCII
                for (0..num_grps) |_| {
                    const start_code = reader.readType(u32);
                    if (start_code > 1 << 7) break;
                    const end_code = reader.readType(u32);
                    const glyph_id = reader.readType(u32);

                    for (start_code..end_code + 1, 0..) |code, idx| {
                        CMAP.put(@intCast(code), @intCast(glyph_id + idx)) catch unreachable;
                    }
                }
            },
            else => assert(false),
        }

        return;
    }
    unreachable;
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
    CMAP.deinit();
}

pub fn draw(str: []const u8, target_buf: DrawBuffer) void {
    const line_spacing = 12;
    var off_x: isize = 0;
    var off_y: isize = 0;
    for (str) |char| {
        var g: Glyph = undefined;
        if (CMAP.get(char) == null) {
            print("char {c} is unsupported\n", .{char});
            g = glyphs[0];
        } else {
            g = glyphs[CMAP.get(char).?];
        }
        if (off_x > target_buf.width) {
            off_x = 0;
            off_y += scale_funits_to_pixels(g.y_max) + line_spacing;
        }
        draw_char(g, target_buf, off_x, off_y);
        off_x += scale_funits_to_pixels(g.x_max);
    }
    target_buf.blit();
}

pub fn draw_char(g: Glyph, target_buf: DrawBuffer, off_x: isize, off_y: isize) void {
    print("glyph: {}\n", .{g});
    print("glyph: {}\n", .{g.data.simple});

    switch (g.data) {
        .simple => |d| {
            for (d.end_pts_of_contour, 0..) |end_pt, i| {
                const num_points = if (i == 0) end_pt + 1 else end_pt - d.end_pts_of_contour[i - 1];
                const start_pt = if (i == 0) 0 else d.end_pts_of_contour[i - 1] + 1;
                const pts = d.coords[start_pt .. end_pt + 1];

                var it: usize = 0;
                if (!pts[it].on_curve) it += 1;
                var covered_pts: usize = 0;

                while (covered_pts < num_points) : (covered_pts += 2) {
                    const p1 = pts[(it + covered_pts) % num_points];
                    const p2 = pts[(it + covered_pts + 1) % num_points];
                    const p3 = pts[(it + covered_pts + 2) % num_points];

                    const from = Vec2{
                        .x = scale_funits_to_pixels(p1.x) + off_x,
                        .y = scale_funits_to_pixels(p1.y) + off_y,
                    };
                    const mid = Vec2{
                        .x = scale_funits_to_pixels(p2.x) + off_x,
                        .y = scale_funits_to_pixels(p2.y) + off_y,
                    };
                    const to = Vec2{
                        .x = scale_funits_to_pixels(p3.x) + off_x,
                        .y = scale_funits_to_pixels(p3.y) + off_y,
                    };
                    // print("going from {},{} to {},{}\r\n", .{ from.x, from.y, to.x, to.y });
                    draw_curve(target_buf, from, mid, to);
                }
            }
        },
        .compound => {},
    }
    for (@intCast(off_x)..@intCast(off_x + scale_funits_to_pixels(g.x_max) + 1)) |x| {
        for (@intCast(off_y)..@intCast(off_y + scale_funits_to_pixels(g.y_max) + 1)) |y| {
            switch (g.data) {
                .simple => |d| {
                    var intersections: usize = 0;
                    for (d.end_pts_of_contour, 0..) |end_pt, i| {
                        const num_points = if (i == 0) end_pt + 1 else end_pt - d.end_pts_of_contour[i - 1];
                        const start_pt = if (i == 0) 0 else d.end_pts_of_contour[i - 1] + 1;
                        const pts = d.coords[start_pt .. end_pt + 1];

                        var it: usize = 0;
                        if (!pts[it].on_curve) it += 1;
                        var covered_pts: usize = 0;

                        while (covered_pts < num_points) : (covered_pts += 2) {
                            const p1 = pts[(it + covered_pts) % num_points];
                            const p2 = pts[(it + covered_pts + 1) % num_points];
                            const p3 = pts[(it + covered_pts + 2) % num_points];

                            const from = Vec2{
                                .x = scale_funits_to_pixels(p1.x) + off_x,
                                .y = scale_funits_to_pixels(p1.y) + off_y,
                            };
                            const mid = Vec2{
                                .x = scale_funits_to_pixels(p2.x) + off_x,
                                .y = scale_funits_to_pixels(p2.y) + off_y,
                            };
                            const to = Vec2{
                                .x = scale_funits_to_pixels(p3.x) + off_x,
                                .y = scale_funits_to_pixels(p3.y) + off_y,
                            };

                            intersections += ray_intersections(from, mid, to, x, y);
                        }
                    }
                    if (intersections % 2 == 1) {
                        target_buf.put_pixel(@intCast(x), @intCast(y), Color{ .r = 255, .g = 0, .b = 0 });
                    }
                },
                .compound => {},
            }
        }
    }
    switch (g.data) {
        .simple => |d| {
            var start_pt: usize = 0;
            var i: usize = 0;
            for (d.end_pts_of_contour) |end_pt| {
                while (i < end_pt) : (i += 2) {
                    const p1 = d.coords[i];
                    const p2 = d.coords[i + 1];
                    var p3: Coord = undefined;
                    if (i == end_pt - 1) {
                        p3 = d.coords[start_pt];
                    } else {
                        p3 = d.coords[i + 2];
                    }

                    const from = Vec2{
                        .x = scale_funits_to_pixels(p1.x) + off_x,
                        .y = scale_funits_to_pixels(p1.y) + off_y,
                    };
                    const mid = Vec2{
                        .x = scale_funits_to_pixels(p2.x) + off_x,
                        .y = scale_funits_to_pixels(p2.y) + off_y,
                    };
                    const to = Vec2{
                        .x = scale_funits_to_pixels(p3.x) + off_x,
                        .y = scale_funits_to_pixels(p3.y) + off_y,
                    };
                    target_buf.put_pixel(@intCast(from.x), @intCast(from.y), if (p1.on_curve) Color{ .r = 0, .g = 0, .b = 255 } else Color{ .r = 0, .g = 255, .b = 0 });
                    target_buf.put_pixel(@intCast(mid.x), @intCast(mid.y), if (p2.on_curve) Color{ .r = 0, .g = 0, .b = 255 } else Color{ .r = 0, .g = 255, .b = 0 });
                    target_buf.put_pixel(@intCast(to.x), @intCast(to.y), if (p3.on_curve) Color{ .r = 0, .g = 0, .b = 255 } else Color{ .r = 0, .g = 255, .b = 0 });
                }
                start_pt = end_pt + 1;
            }
        },
        .compound => {},
    }
}

fn scale_funits_to_pixels(val: isize) i64 {
    const font_size = 50.0;
    const ppi = 227.0;
    const ppem: f32 = font_size * ppi / 72.0;
    const scale: f32 = ppem / @as(f32, @floatFromInt(HEAD.units_per_em));
    return @intFromFloat(@round(@as(f32, @floatFromInt(val)) * scale));
}

fn ray_intersections(p1: Vec2, p2: Vec2, p3: Vec2, ray_origin_x: usize, y_shift: usize) usize {
    // the equation of a bezier curve is (p1 - 2p2 + p3)t^2 + 2t(p2-p1) + p1
    // we want to test how many intersections a horizontal line at y_shift makes with this curve
    // what value of t will make the resulting bezier point 0
    // only care about y component as we want to know what t causes y to be 0
    const a: f32 = @floatFromInt(p1.sub(p2.mult(2)).add(p3).y);
    const b: f32 = @floatFromInt(p2.sub(p1).mult(2).y);
    const c: f32 = @floatFromInt(p1.y - @as(isize, @intCast(y_shift)));

    var intersections: usize = 0;
    if (a == 0) {
        const t = -c / b;
        if (is_valid_intersection(t, p1, p2, p3, ray_origin_x)) intersections += 1;
    } else {
        // quadratic formula
        const temp = @sqrt(b * b - 4 * a * c);
        const t_plus = (-b + temp) / (2 * a);
        const t_minus = (-b - temp) / (2 * a);
        // only care about values between 0 and 1 since we only interpolate between these
        if (is_valid_intersection(t_plus, p1, p2, p3, ray_origin_x)) intersections += 1;
        if (is_valid_intersection(t_minus, p1, p2, p3, ray_origin_x)) intersections += 1;
    }
    return intersections;
}

fn is_valid_intersection(t: f32, p1: Vec2, p2: Vec2, p3: Vec2, ray_origin_x: usize) bool {
    return t >= 0 and t < 1 and bezier_interp(p1, p2, p3, t).x >= ray_origin_x;
}

fn bresenham_line(target_buf: DrawBuffer, from: Vec2, to: Vec2) void {
    var dx: i64 = to.x - from.x;
    var dy: i64 = to.y - from.y;
    const pixel_dx: i8 = if (dx > 0) 1 else -1;
    const pixel_dy: i8 = if (dy > 0) 1 else -1;
    if (pixel_dx < 0) dx = -dx;
    if (pixel_dy < 0) dy = -dy;
    var cursor_x: i64 = from.x;
    var cursor_y: i64 = from.y;
    if (@abs(dx) >= @abs(dy)) {
        var D: i64 = 2 * dy - dx;
        while (cursor_x != to.x) {
            target_buf.put_pixel(@intCast(cursor_x), @intCast(cursor_y), Color{ .r = 255, .g = 0, .b = 0 });
            cursor_x += pixel_dx;
            if (cursor_y != to.y) {
                if (D > 0) {
                    cursor_y += pixel_dy;
                    D += 2 * dy - 2 * dx;
                } else {
                    D += 2 * dy;
                }
            }
            // target_buf.blit();
        }
    } else {
        var D: i64 = 2 * dx - dy;
        while (cursor_y != to.y) {
            target_buf.put_pixel(@intCast(cursor_x), @intCast(cursor_y), Color{ .r = 255, .g = 0, .b = 0 });
            cursor_y += pixel_dy;
            if (cursor_x != to.x) {
                if (D > 0) {
                    cursor_x += pixel_dx;
                    D += 2 * dx - 2 * dy;
                } else {
                    D += 2 * dx;
                }
            }
            // target_buf.blit();
        }
    }
}

fn lerp(p1: Vec2, p2: Vec2, t: f64) Vec2 {
    return p1.add(p2.sub(p1).mult(t));
}

fn bezier_interp(p1: Vec2, p2: Vec2, p3: Vec2, t: f64) Vec2 {
    const interA = lerp(p1, p2, t);
    const interB = lerp(p2, p3, t);
    return lerp(interA, interB, t);
}

fn draw_curve(target_buf: DrawBuffer, p1: Vec2, p2: Vec2, p3: Vec2) void {
    const res = 2;
    var prev = bezier_interp(p1, p2, p3, 0);
    for (0..res) |i| {
        const t = (1.0 + @as(f32, @floatFromInt(i))) / res;
        const cur = bezier_interp(p1, p2, p3, t);
        bresenham_line(target_buf, prev, cur);
        prev = cur;
    }
}

fn find_record(tag: []const u8) ?TableRecord {
    for (0..records.len) |i| {
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
    on_curve: bool,
};

const Vec2 = struct {
    x: i64,
    y: i64,

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return Vec2{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return Vec2{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn mult(self: Vec2, s: f64) Vec2 {
        return Vec2{ .x = @intFromFloat(@as(f64, @floatFromInt(self.x)) * s), .y = @intFromFloat(@as(f64, @floatFromInt(self.y)) * s) };
    }
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

            const on_curve_mask = 0;
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

            var coords = try std.ArrayList(Coord).initCapacity(allocator, @intCast(num_points));
            for (0..num_points) |j| {
                var coord: Coord = undefined;
                const flag = flags[j];
                coord.on_curve = isBitSet(flag, on_curve_mask);

                var x: i16 = 0;
                if (j != 0) {
                    x = @intCast(coords.items[j - 1].x);
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
                coord.x = @intCast(x);
                coords.appendAssumeCapacity(coord);
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
                    coords.items[j].y = @intCast(y);
                } else {
                    // all coordinates are relative from the first one
                    // deltas are now flipped
                    var y = coords.items[j - 1].y;
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
                                y -= @intCast(delta);
                            } else {
                                y += @intCast(-delta);
                            }
                            byte_ptr += 2;
                        }
                    }
                    coords.items[j].y = y;
                }
            }
            // Insert a bunch of intermediary points to turn everything into a bezier
            var k: usize = 0;
            var inserted: u16 = 0;
            for (data.simple.end_pts_of_contour, 0..) |end_pt, j| {
                const start_pt: usize = if (j == 0) 0 else data.simple.end_pts_of_contour[j - 1] + 1;
                while (k <= end_pt + inserted) : (k += 1) {
                    const p1 = coords.items[k];
                    var p2: Coord = undefined;
                    if (k == end_pt + inserted) {
                        p2 = coords.items[start_pt];
                    } else {
                        p2 = coords.items[k + 1];
                    }
                    // implied mid point between these 2 coords is on curve
                    if (!p1.on_curve and !p2.on_curve) {
                        const mid = Coord{ .x = (p1.x + p2.x) / 2, .y = (p1.y + p2.y) / 2, .on_curve = true };
                        try coords.insert(k + 1, mid);
                        k += 1;
                        inserted += 1;
                    } else if (p1.on_curve and p2.on_curve) {
                        // consecutive on_curve represents a straight line, add implied off curve mid point to turn it into a bezier as well for ease
                        const mid = Coord{ .x = (p1.x + p2.x) / 2, .y = (p1.y + p2.y) / 2, .on_curve = false };
                        try coords.insert(k + 1, mid);
                        k += 1;
                        inserted += 1;
                    }
                }
                data.simple.end_pts_of_contour[j] += inserted;
            }
            g.x_min = 0;
            g.x_max -= g.x_min;
            g.y_min = 0;
            g.y_max = g.y_max - g.y_min;
            // if (i == CMAP.get('B').?) print("{}\r\n", .{coords});
            data.simple.coords = try coords.toOwnedSlice();
            g.data = data;
        }
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
    const testing = @import("std").testing;
    const cwd = std.fs.cwd();
    const f = try cwd.openFile("out/efi/boot/Helvetica.ttf", std.fs.File.OpenFlags{});
    var buf: [1024 * 1024 * 10]u8 = undefined;
    std.debug.print("size: {}\n", .{@sizeOf(u16)});
    const size = try f.readAll(&buf);
    try ttf_load(std.testing.allocator, buf[0..size]);
    defer ttf_unload(std.testing.allocator);
    const g = glyphs[CMAP.get('B').?];
    std.debug.print("{}\n", .{g});
    std.debug.print("{}\n", .{g.data});
    const c1 = g.data.simple.end_pts_of_contour[0];
    // const c2 = g.data.simple.end_pts_of_contour[1];
    std.debug.print("{any}\n\n", .{g.data.simple.coords[0 .. c1 + 1]});
    std.debug.print("{any}\n", .{g.data.simple.coords[c1 + 1 ..]});
    for (g.data.simple.coords[0 .. c1 + 1]) |a| {
        for (g.data.simple.coords[c1 + 1 ..]) |b| {
            testing.expect(b.x <= a.x) catch {
                std.debug.print("a: {} b: {}\n", .{ a, b });
            };
        }
    }
}

test "floats" {
    const f: f32 = 0.0;
    const a: f32 = 0.0;
    print("{}\n", .{a / f});
}

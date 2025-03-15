const std = @import("std");
const builtin = @import("builtin");
const Font = @This();
const native_endian = builtin.cpu.arch.endian();
scalar_type: enum(u32) {
    truetype = 0x00010000,
    opentype = 0x4F54544F,
    _,
},
table_offsets: [@typeInfo(TableIndex).@"enum".fields.len]u32,
table_lengths: [@typeInfo(TableIndex).@"enum".fields.len]u32,
bytes: []const u8,
char_map: CharMap,
index_to_loc_format: enum { short, long },
pub fn parse(bytes: []const u8) !Font {
    var font: Font = .{
        .table_offsets = @splat(0),
        .table_lengths = @splat(0),
        .scalar_type = undefined,
        .bytes = bytes,
        .char_map = undefined,
        .index_to_loc_format = undefined,
    };
    var reader = font.fontReader(0);
    font.scalar_type = @enumFromInt(reader.read(u32));
    const num_tables = reader.read(u16);
    reader.skip(6); // searchRange, entrySelector, rangeShift
    std.debug.print("{}\n", .{num_tables});
    for (0..num_tables) |_| {
        std.debug.print("{s}\n", .{bytes[reader.offset..][0..4]});
        const tag_int = std.mem.bigToNative(u32, reader.read(u32));
        const check_sum = reader.read(u32);
        const table_offset = reader.read(u32);
        const table_length = reader.read(u32);

        const tag: TableIndex = switch (tag_int) {
            TableIndex.head.toTag() => .head,
            TableIndex.cmap.toTag() => .cmap,
            TableIndex.glyf.toTag() => .glyf,
            TableIndex.loca.toTag() => .loca,
            else => continue,
        };
        font.table_offsets[@intFromEnum(tag)] = table_offset;
        font.table_lengths[@intFromEnum(tag)] = table_length;
        _ = check_sum;
    }
    font.char_map = try font.parseCmap();
    font.index_to_loc_format = @enumFromInt(font.parseHead());
    return font;
}

fn fontReader(font: *const Font, offset: u32) FontReader {
    return .{
        .bytes = font.bytes,
        .offset = offset,
    };
}

fn tableReader(font: *const Font, table: TableIndex) FontReader {
    return .{
        .bytes = font.bytes,
        .offset = font.table_offsets[@intFromEnum(table)],
    };
}

const FontReader = struct {
    bytes: []const u8,
    offset: u32,
    fn read(reader: *FontReader, T: type) T {
        const bytes = @divExact(@typeInfo(T).int.bits, 8);
        const val: T = @bitCast(reader.bytes[reader.offset..][0..bytes].*);
        reader.offset += bytes;
        return std.mem.bigToNative(T, val);
    }
    fn readFrom(reader: *FontReader, T: type, offset: u32) T {
        reader.skip(offset);
        return reader.read(T);
    }
    fn skip(reader: *FontReader, offset: u32) void {
        reader.offset += offset;
    }
    fn reset(reader: *FontReader, offset: u32) void {
        reader.offset = offset;
    }
};

fn parseHead(font: *const Font) i16 {
    var reader = font.tableReader(.head);
    reader.skip(2); // major version
    reader.skip(2); // minor version
    reader.skip(4); // font revision
    reader.skip(4); // checksum adjustment
    reader.skip(4); // magic number
    reader.skip(2); // flags
    reader.skip(2); // units per em
    reader.skip(8); // created
    reader.skip(8); // modified
    reader.skip(2); // x min
    reader.skip(2); // y min
    reader.skip(2); // x max
    reader.skip(2); // y max
    reader.skip(2); // mac style
    reader.skip(2); // lowest rec PPEM
    reader.skip(2); // font direction hint
    return reader.read(i16);
}

const CMapSubtable = packed struct {
    platform_id: u16,
    platform_specific_id: u16,
    offset: u32,
};
fn parseCmap(font: *const Font) !CharMap {
    const cmap_offset = font.table_offsets[@intFromEnum(TableIndex.cmap)];
    var reader = font.fontReader(cmap_offset);
    reader.skip(2);
    const num_subtables = reader.read(u16);
    var prefered_subtable: ?CMapSubtable = null;
    const preference = [_]u16{ 4, 1, 0, 3, 5, 6 };
    for (0..num_subtables) |_| {
        const subtable: CMapSubtable = .{
            .platform_id = reader.read(u16),
            .platform_specific_id = reader.read(u16),
            .offset = reader.read(u32),
        };
        if (subtable.platform_id > 0) continue;
        const index = std.mem.indexOfScalar(u16, &preference, subtable.platform_specific_id) orelse continue;
        if (prefered_subtable) |prefered| {
            const prefered_index = std.mem.indexOfScalar(u16, &preference, prefered.platform_specific_id).?;
            if (index < prefered_index) {
                prefered_subtable = subtable;
            }
        } else {
            prefered_subtable = subtable;
        }
    }
    reader.reset(cmap_offset);
    reader.skip((prefered_subtable orelse return error.NoSuitableCmap).offset);
    const format = reader.read(u16);
    return .{
        .format = format,
        .start = reader.offset,
    };
}

pub const GlyphHead = struct {
    contours: u16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};
pub const Glyph = struct {
    bitmap: []const [4]u8,
    width: u32,
    height: u32,
};
const CoordFlag = packed struct {
    on_curve: bool,
    x_short: bool,
    y_short: bool,
    repeat: bool,
    x_same_or_positive: bool,
    y_same_or_positive: bool,
    overlap: bool,
    reserved: bool,
    fn xSign(flag: CoordFlag) i16 {
        return if (flag.x_short and flag.x_same_or_positive) 1 else -1;
    }
    fn ySign(flag: CoordFlag) i16 {
        return if (flag.y_short and flag.y_same_or_positive) 1 else -1;
    }
};
const Coord = struct {
    x: i32,
    y: i32,
};
pub fn indexToLoc(font: *const Font, index: u32) u32 {
    var reader = font.tableReader(.loca);
    return switch (font.index_to_loc_format) {
        .short => reader.readFrom(u16, index * 2) * 2,
        .long => reader.readFrom(u32, index * 4),
    };
}

pub const GlyphData = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    coords: []Coord,
    flags: []CoordFlag,
    end_points: []u16,
};

// TODO: return iterators so to make it zero alloc
pub fn glyphData(font: *const Font, alloc: std.mem.Allocator, index: u32) !GlyphData {
    var reader = font.tableReader(.glyf);
    reader.skip(font.indexToLoc(index));
    const contours = reader.read(i16);
    const x_min = reader.read(i16);
    const y_min = reader.read(i16);
    const x_max = reader.read(i16);
    const y_max = reader.read(i16);
    const combined = contours == -1;
    if (combined) @panic("todo");
    const end_points = try alloc.alloc(u16, @intCast(contours));
    for (end_points) |*point| {
        point.* = reader.read(u16);
    }
    const instruction_length = reader.read(u16);
    reader.skip(instruction_length); // instructions
    const num_coords = end_points[end_points.len - 1] + 1;
    var flags = try alloc.alloc(CoordFlag, num_coords);
    var i: usize = 0;
    while (i < num_coords) {
        const coord: CoordFlag = @bitCast(reader.read(u8));
        flags[i] = coord;
        i += 1;
        if (coord.repeat) {
            const repeat = reader.read(u8);
            @memset(flags[i..][0..repeat], coord);
            i += repeat;
        }
    }
    var coords = try alloc.alloc(Coord, num_coords);
    var x: i32 = 0;
    for (flags, 0..) |flag, idx| {
        if (flag.x_short) {
            const coord = reader.read(u8);
            x += coord * flag.xSign();
            coords[idx].x = x;
        } else {
            if (!flag.x_same_or_positive) {
                const coord = reader.read(i16);
                x += coord;
            }
            coords[idx].x = x;
        }
    }
    var y: i32 = 0;
    for (flags, 0..) |flag, idx| {
        if (flag.y_short) {
            const coord = reader.read(u8);
            y += coord * flag.ySign();
            coords[idx].y = y;
        } else {
            if (!flag.y_same_or_positive) {
                const coord = reader.read(i16);
                y += coord;
            }
            coords[idx].y = y;
        }
    }
    return .{
        .y_max = y_max,
        .y_min = y_min,
        .x_max = x_max,
        .x_min = x_min,
        .flags = flags,
        .coords = coords,
        .end_points = end_points,
    };
}
pub fn renderGlyph(font: *const Font, alloc: std.mem.Allocator, index: u32) !Glyph {
    const data = try font.glyphData(alloc, index);
    alloc.free(data.flags);
    alloc.free(data.end_points);
    defer alloc.free(data.coords);
    const height: u32 = @intCast(data.y_max - data.y_min + 48);
    const width: u32 = @intCast(data.x_max - data.x_min + 48);
    const bitmap = try alloc.alloc([4]u8, width * height);
    @memset(bitmap, .{ 0, 0, 0, 0xFF });
    for (data.coords) |coord| {
        const cx: u32 = @intCast(coord.x - data.x_min + 24);
        const cy: u32 = @intCast(coord.y - data.y_min + 24);
        for (0..16) |xs| {
            for (0..16) |ys| {
                bitmap[std.math.clamp(cy + ys -% 8, 0, height - 1) * width + std.math.clamp(cx + xs -% 8, 0, width - 1)] = @splat(0xFF);
            }
        }
    }
    return .{
        .height = height,
        .width = width,
        .bitmap = bitmap,
    };
}

pub fn charToGlyph(font: *const Font, codepoint: u21) u32 {
    var reader = font.fontReader(font.char_map.start);
    switch (font.char_map.format) {
        12 => {
            reader.skip(2 + 4 + 4); // reserved, length, language
            const groups = reader.read(u32);
            for (0..groups) |_| {
                const start_char = reader.read(u32);
                const end_char = reader.read(u32);
                const start_glyph = reader.read(u32);
                if (codepoint >= start_char and codepoint <= end_char) {
                    return start_glyph + codepoint - start_char;
                }
            }
        },
        else => {},
    }
    return 0;
}

pub const TableIndex = enum {
    head,
    cmap,
    glyf,
    loca,
    fn toTag(index: TableIndex) u32 {
        const bytes: [4]u8 = @tagName(index).*;
        return @bitCast(bytes);
    }
};

const CharMap = struct {
    format: u16,
    start: u32,
};

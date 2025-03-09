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
    var offset: usize = 0;
    var font: Font = .{
        .table_offsets = @splat(0),
        .table_lengths = @splat(0),
        .scalar_type = @enumFromInt(std.mem.readInt(u32, bytes[0..4], .big)),
        .bytes = bytes,
        .char_map = undefined,
        .index_to_loc_format = undefined,
    };
    offset += 4;
    const num_tables = std.mem.readInt(u16, bytes[offset..][0..2], .big);
    offset += 2;
    offset += 6; // searchRange, entrySelector, rangeShift
    std.debug.print("{}\n", .{num_tables});
    for (0..num_tables) |_| {
        const tag_int = std.mem.readInt(u32, bytes[offset..][0..4], native_endian);
        std.debug.print("{s}\n", .{bytes[offset..][0..4]});
        offset += 4;
        const check_sum = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        const table_offset = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        const table_length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;

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

fn parseHead(font: *const Font) i16 {
    var offset = font.table_offsets[@intFromEnum(TableIndex.head)];
    offset += 2; // major version
    offset += 2; // minor version
    offset += 4; // font revision
    offset += 4; // checksum adjustment
    offset += 4; // magic number
    offset += 2; // flags
    offset += 2; // units per em
    offset += 8; // created
    offset += 8; // modified
    offset += 2; // x min
    offset += 2; // y min
    offset += 2; // x max
    offset += 2; // y max
    offset += 2; // mac style
    offset += 2; // lowest rec PPEM
    offset += 2; // font direction hint
    return std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
}
const CMapSubtable = packed struct {
    platform_id: u16,
    platform_specific_id: u16,
    offset: u32,
};
fn parseCmap(font: *const Font) !CharMap {
    const cmap_offset = font.table_offsets[@intFromEnum(TableIndex.cmap)];
    var offset = cmap_offset;
    _ = std.mem.readInt(u16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const num_subtables = std.mem.readInt(u16, font.bytes[offset..][0..2], .big);
    offset += 2;
    var prefered_subtable: ?CMapSubtable = null;
    const preference = [_]u16{ 4, 1, 0, 3, 5, 6 };
    for (0..num_subtables) |_| {
        const subtable: CMapSubtable = .{
            .platform_id = std.mem.readInt(u16, font.bytes[offset..][0..2], .big),
            .platform_specific_id = std.mem.readInt(u16, font.bytes[offset + 2 ..][0..2], .big),
            .offset = std.mem.readInt(u32, font.bytes[offset + 4 ..][0..4], .big),
        };
        offset += 8;
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
    offset = cmap_offset + (prefered_subtable orelse return error.NoSuitableCmap).offset;
    const format = std.mem.readInt(u16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const start = offset;
    return .{
        .format = format,
        .start = start,
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
    fn xPrev(flag: CoordFlag) bool {
        return !flag.x_short and flag.x_same_or_positive;
    }
    fn yPrev(flag: CoordFlag) bool {
        return !flag.y_short and flag.y_same_or_positive;
    }
};
const Coord = struct {
    x: i32,
    y: i32,
};
pub fn indexToLoc(font: *const Font, index: u32) u32 {
    const offset = font.table_offsets[@intFromEnum(TableIndex.loca)];
    return switch (font.index_to_loc_format) {
        .short => std.mem.readInt(u16, font.bytes[offset + index * 2 ..][0..2], .big) * 2,
        .long => std.mem.readInt(u32, font.bytes[offset + index * 4 ..][0..4], .big),
    };
}
pub fn renderGlyph(font: *const Font, alloc: std.mem.Allocator, index: u32) !Glyph {
    var offset = font.table_offsets[@intFromEnum(TableIndex.glyf)] + font.indexToLoc(index);
    const contours = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const x_min = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const y_min = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const x_max = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const y_max = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
    offset += 2;
    const combined = contours == -1;
    if (combined) @panic("todo");
    const end_points = try alloc.alloc(u16, @intCast(contours));
    defer alloc.free(end_points);
    for (end_points) |*point| {
        point.* = std.mem.readInt(u16, font.bytes[offset..][0..2], .big);
        offset += 2;
    }
    const instruction_length = std.mem.readInt(u16, font.bytes[offset..][0..2], .big);
    offset += 2;
    offset += instruction_length; // instructions
    const num_coords = end_points[end_points.len - 1] + 1;
    var flags = try alloc.alloc(CoordFlag, num_coords);
    defer alloc.free(flags);
    var i: usize = 0;
    while (i < num_coords) {
        const coord: CoordFlag = @bitCast(std.mem.readInt(u8, font.bytes[offset..][0..1], .big));
        offset += 1;
        flags[i] = coord;
        i += 1;
        if (coord.repeat) {
            const repeat = std.mem.readInt(u8, font.bytes[offset..][0..1], .big);
            offset += 1;
            @memset(flags[i..][0..repeat], coord);
            i += repeat;
        }
    }
    var coords = try alloc.alloc(Coord, num_coords);
    defer alloc.free(coords);
    var x: i32 = 0;
    for (flags, 0..) |flag, idx| {
        if (flag.x_short) {
            const coord = std.mem.readInt(u8, font.bytes[offset..][0..1], .big);
            offset += 1;
            x += coord * flag.xSign();
            coords[idx].x = x;
        } else {
            if (!flag.x_same_or_positive) {
                const coord = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
                offset += 2;
                x += coord;
            }
            coords[idx].x = x;
        }
    }
    var y: i32 = 0;
    for (flags, 0..) |flag, idx| {
        if (flag.y_short) {
            const coord = std.mem.readInt(u8, font.bytes[offset..][0..1], .big);
            offset += 1;
            y += coord * flag.ySign();
            coords[idx].y = y;
        } else {
            if (!flag.y_same_or_positive) {
                const coord = std.mem.readInt(i16, font.bytes[offset..][0..2], .big);
                offset += 2;
                y += coord;
            }
            coords[idx].y = y;
        }
    }
    const height: u32 = @intCast(y_max - y_min + 48);
    const width: u32 = @intCast(x_max - x_min + 48);
    const bitmap = try alloc.alloc([4]u8, width * height);
    @memset(bitmap, .{ 0, 0, 0, 0xFF });
    for (coords) |coord| {
        const cx: u32 = @intCast(coord.x - x_min + 24);
        const cy: u32 = @intCast(coord.y - y_min + 24);
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
    var offset = font.char_map.start;
    switch (font.char_map.format) {
        12 => {
            offset += 2 + 4 + 4; // reserved, length, language
            const groups = std.mem.readInt(u32, font.bytes[offset..][0..4], .big);
            offset += 4;
            for (0..groups) |_| {
                const start_char = std.mem.readInt(u32, font.bytes[offset..][0..4], .big);
                offset += 4;
                const end_char = std.mem.readInt(u32, font.bytes[offset..][0..4], .big);
                offset += 4;
                const start_glyph = std.mem.readInt(u32, font.bytes[offset..][0..4], .big);
                offset += 4;
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

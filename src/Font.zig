const std = @import("std");
const builtin = @import("builtin");
const Glyph = @import("Glyph.zig");

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

pub fn fontReader(font: *const Font, offset: u32) FontReader {
    return .{
        .bytes = font.bytes,
        .offset = offset,
    };
}

pub fn tableReader(font: *const Font, table: TableIndex) FontReader {
    return .{
        .bytes = font.bytes,
        .offset = font.table_offsets[@intFromEnum(table)],
    };
}

const FontReader = struct {
    bytes: []const u8,
    offset: u32,
    pub fn read(reader: *FontReader, T: type) T {
        const bytes = @divExact(@typeInfo(T).int.bits, 8);
        const val: T = @bitCast(reader.bytes[reader.offset..][0..bytes].*);
        reader.offset += bytes;
        return std.mem.bigToNative(T, val);
    }
    pub fn readFrom(reader: *FontReader, T: type, offset: u32) T {
        reader.skip(offset);
        return reader.read(T);
    }
    pub fn skip(reader: *FontReader, offset: u32) void {
        reader.offset += offset;
    }
    pub fn reset(reader: *FontReader, offset: u32) void {
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

pub fn indexToLoc(font: *const Font, index: u32) u32 {
    var reader = font.tableReader(.loca);
    return switch (font.index_to_loc_format) {
        .short => reader.readFrom(u16, index * 2) * 2,
        .long => reader.readFrom(u32, index * 4),
    };
}

pub fn glyphData(font: *const Font, index: u32) Glyph {
    var reader = font.tableReader(.glyf);
    reader.skip(font.indexToLoc(index));
    const contours = reader.read(i16);
    const x_min = reader.read(i16);
    const y_min = reader.read(i16);
    const x_max = reader.read(i16);
    const y_max = reader.read(i16);
    const combined = contours == -1;
    if (combined) @panic("todo");
    const contours_u: u16 = @intCast(contours);
    const end_points_start = reader.offset;
    reader.skip((contours_u - 1) * 2);
    const num_coords = reader.read(u16) + 1;
    const instruction_length = reader.read(u16);
    reader.skip(instruction_length); // instructions
    const flags_start = reader.offset;
    var i: usize = 0;
    while (i < num_coords) {
        const coord: Glyph.CoordFlag = @bitCast(reader.read(u8));
        i += 1;
        if (coord.repeat) {
            const repeat = reader.read(u8);
            i += repeat;
        }
    }
    var flag_reader = font.fontReader(flags_start);
    var flag_repeat: u8 = 0;
    var repeat_flag: Glyph.CoordFlag = undefined;
    const x_coords_start = reader.offset;
    for (0..i) |_| {
        const flag = blk: {
            if (flag_repeat > 0) {
                flag_repeat -= 1;
                break :blk repeat_flag;
            }
            const coord: Glyph.CoordFlag = @bitCast(flag_reader.read(u8));
            if (coord.repeat) {
                flag_repeat = flag_reader.read(u8);
            }
            repeat_flag = coord;
            break :blk coord;
        };
        if (flag.x_short) {
            reader.skip(1);
        } else {
            if (!flag.x_same_or_positive) {
                reader.skip(2);
            }
        }
    }
    const y_coords_start = reader.offset;
    return .{
        .y_max = y_max,
        .y_min = y_min,
        .x_max = x_max,
        .x_min = x_min,
        .flags_start = flags_start,
        .x_coords_start = x_coords_start,
        .y_coords_start = y_coords_start,
        .end_points_start = end_points_start,
        .contours = contours_u,
        .num_coords = num_coords,
    };
}

pub fn charToGlyph(font: *const Font, codepoint: u21) u32 {
    var reader = font.fontReader(font.char_map.start);
    switch (font.char_map.format) {
        4 => {
            reader.skip(2 + 2); // length, language
            const seg_count = reader.read(u16) / 2;
            _ = reader.read(u16);
            _ = reader.read(u16);
            _ = reader.read(u16);
            var i: u32 = 0;
            while (i < seg_count) : (i += 1) {
                const end_code = reader.read(u16);
                if (codepoint <= end_code) {
                    break;
                }
            }
            reader.skip((seg_count - i - 1) * 2);

            reader.skip(2); // reserved pad

            const start_code = reader.readFrom(u16, 2 * i);
            reader.skip((seg_count - i - 1) * 2);

            const id_delta = reader.readFrom(i16, 2 * i);
            reader.skip((seg_count - i - 1) * 2);

            const id_range_offset = reader.readFrom(u16, 2 * i);

            if (id_range_offset == 0) {
                const glyph_index: i32 = @as(i32, @intCast(codepoint)) + id_delta;
                const unsigned: u32 = @intCast(if (glyph_index < 0) glyph_index + 65536 else glyph_index);
                return unsigned % 65536;
            }
            // subtract 2 bytes because its an offset from the id_range_offset
            const glyph_index: i32 = reader.readFrom(u16, id_range_offset + (codepoint - start_code) * 2 - 2);
            if (glyph_index == 0) return 0;

            const signed = glyph_index + id_delta;
            const unsigned: u32 = @intCast(if (signed < 0) signed + 65536 else signed);
            return unsigned % 65536;
        },
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

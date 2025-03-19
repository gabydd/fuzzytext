const std = @import("std");
const fuzzy = @import("fuzzytext");
const Font = fuzzy.Font;

const file = @embedFile("res/Inconsolata-Regular.ttf");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const font: Font = try .parse(file);
    for (font.table_lengths, font.table_offsets, 0..) |length, offset, i| {
        std.debug.print("tag: {}; offset: {}; length: {}\n", .{ @as(Font.TableIndex, @enumFromInt(i)), offset, length });
    }
    std.debug.print("{}\n", .{font.charToGlyph('D')});
    try run(&font);
}

const shimizu = @import("shimizu");
const wp = @import("wayland-protocols");
const xdg_shell = wp.xdg_shell;

const Globals = struct {
    wl_shm: ?shimizu.core.wl_shm,
    wl_compositor: ?shimizu.core.wl_compositor,
    xdg_wm_base: ?xdg_shell.xdg_wm_base,

    fn onRegistryEvent(globals: *Globals, connection: shimizu.Connection, registry: shimizu.core.wl_registry, event: shimizu.core.wl_registry.Event) !void {
        switch (event) {
            .global => |global| {
                if (shimizu.globalMatchesInterface(global, shimizu.core.wl_compositor)) {
                    globals.wl_compositor = @enumFromInt(@intFromEnum(try registry.bind(connection, global.name, shimizu.core.wl_compositor.NAME, shimizu.core.wl_compositor.VERSION)));
                } else if (shimizu.globalMatchesInterface(global, xdg_shell.xdg_wm_base)) {
                    globals.xdg_wm_base = @enumFromInt(@intFromEnum(try registry.bind(connection, global.name, xdg_shell.xdg_wm_base.NAME, xdg_shell.xdg_wm_base.VERSION)));
                } else if (shimizu.globalMatchesInterface(global, shimizu.core.wl_shm)) {
                    globals.wl_shm = @enumFromInt(@intFromEnum(try registry.bind(connection, global.name, shimizu.core.wl_shm.NAME, shimizu.core.wl_shm.VERSION)));
                }
            },
            else => {},
        }
    }
};

pub fn run(font: *const Font) !void {
    var debug = std.heap.DebugAllocator(.{}){};
    defer _ = debug.deinit();
    const alloc = debug.allocator();

    var connection = try shimizu.posix.Connection.open(alloc, .{});
    const conn = connection.connection();
    defer connection.close();

    const display = connection.getDisplay();
    const registry = try display.get_registry(connection.connection());
    const registry_done_callback = try display.sync(connection.connection());

    var globals: Globals = .{
        .wl_shm = null,
        .wl_compositor = null,
        .xdg_wm_base = null,
    };

    var state: WindowState = .{
        .height = 0,
        .width = 0,
        .should_close = false,
    };

    try conn.setEventListener(registry, *Globals, Globals.onRegistryEvent, &globals);

    var registration_done = false;
    try conn.setEventListener(registry_done_callback, *bool, onWlCallbackSetTrue, &registration_done);

    while (!registration_done) {
        try connection.recv();
    }

    const wl_compositor = globals.wl_compositor orelse return error.WlCompositorNotFound;
    const xdg_wm_base = globals.xdg_wm_base orelse return error.XdgWmBaseNotFound;
    const wl_shm = globals.wl_shm orelse return error.WlShmNotFound;

    const wl_surface = try wl_compositor.create_surface(conn);
    const xdg_surface = try xdg_wm_base.get_xdg_surface(conn, wl_surface);
    const xdg_toplevel = try xdg_surface.get_toplevel(conn);

    try wl_surface.commit(conn);

    var surface_configured = false;
    try conn.setEventListener(xdg_surface, *bool, onXdgSurfaceEvent, &surface_configured);
    try conn.setEventListener(xdg_toplevel, *WindowState, onXdgToplevelEvent, &state);

    while (!surface_configured) {
        try connection.recv();
    }

    // rgba pixels
    const Pixel = [4]u8;
    const frambuffer_byte_size = state.height * state.width * @sizeOf(Pixel);

    const fd = try std.posix.memfd_create("framebuffer", 0);
    defer std.posix.close(fd);
    try std.posix.ftruncate(fd, frambuffer_byte_size);

    // mmap the framebuffer and set all the pixels to opaque black
    const OPAQUE_BLACK = [4]u8{ 0, 0, 0, 0xFF };
    const memory = try std.posix.mmap(null, frambuffer_byte_size, std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    const pixels: []Pixel = std.mem.bytesAsSlice(Pixel, memory);
    @memset(pixels, OPAQUE_BLACK);
    const glyph = font.glyphData(font.charToGlyph('}'));
    const render = try glyph.renderOutline(font, alloc);
    defer alloc.free(render.bitmap);
    for (0..render.height) |i| {
        @memcpy(pixels[i * state.width ..][0..render.width], render.bitmap[i * render.width ..][0..render.width]);
    }

    // create a Wayland shared memory pool
    const wl_shm_pool = try wl_shm.create_pool(
        conn,
        @enumFromInt(fd),
        @intCast(frambuffer_byte_size),
    );

    // create a wl_buffer from the framebuffer
    const wl_buffer = try wl_shm_pool.create_buffer(
        conn,
        0,
        @intCast(state.width),
        @intCast(state.height),
        // The number of bytes between rows pixels
        @intCast(state.width * @sizeOf(Pixel)),
        .argb8888,
    );

    // attach the wl_buffer to our window
    try wl_surface.attach(conn, wl_buffer, 0, 0);
    try wl_surface.damage(conn, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    try wl_surface.commit(conn);

    while (!state.should_close) {
        try connection.recv();
    }
}

fn onXdgSurfaceEvent(surface_configured: *bool, connection: shimizu.Connection, xdg_surface: xdg_shell.xdg_surface, event: xdg_shell.xdg_surface.Event) !void {
    switch (event) {
        .configure => |configure| {
            try xdg_surface.ack_configure(connection, configure.serial);
            surface_configured.* = true;
        },
    }
}

const WindowState = struct {
    width: u32,
    height: u32,
    should_close: bool,
};
fn onXdgToplevelEvent(state: *WindowState, connection: shimizu.Connection, xdg_toplevel: xdg_shell.xdg_toplevel, event: xdg_shell.xdg_toplevel.Event) !void {
    _ = connection;
    _ = xdg_toplevel;
    switch (event) {
        .configure => |configure| {
            state.height = @intCast(configure.height);
            state.width = @intCast(configure.width);
        },
        .close => state.should_close = true,
        else => {},
    }
}

fn onWlCallbackSetTrue(bool_ptr: *bool, connection: shimizu.Connection, wl_callback: shimizu.core.wl_callback, event: shimizu.core.wl_callback.Event) !void {
    _ = connection;
    _ = wl_callback;
    _ = event;

    bool_ptr.* = true;
}

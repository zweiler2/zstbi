const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const mem_alignment = 16;
var zstb_io: std.Io = undefined;
var mem_allocator: ?std.mem.Allocator = null;
var mem_allocations: ?std.AutoHashMap(usize, usize) = null;
var mem_mutex: std.Io.Mutex = .init;

extern var zstbi_image_MallocPtr: ?*const fn (size: usize) callconv(.c) ?*anyopaque;
extern var zstbi_image_ReallocPtr: ?*const fn (ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern var zstbi_image_FreePtr: ?*const fn (maybe_ptr: ?*anyopaque) callconv(.c) void;

extern var zstbi_resize_MallocPtr: ?*const fn (size: usize, maybe_context: ?*anyopaque) callconv(.c) ?*anyopaque;
extern var zstbi_resize_FreePtr: ?*const fn (maybe_ptr: ?*anyopaque, maybe_context: ?*anyopaque) callconv(.c) void;

extern var zstbi_write_MallocPtr: ?*const fn (size: usize) callconv(.c) ?*anyopaque;
extern var zstbi_write_ReallocPtr: ?*const fn (ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern var zstbi_write_FreePtr: ?*const fn (maybe_ptr: ?*anyopaque) callconv(.c) void;

pub fn init(io: std.Io, allocator: std.mem.Allocator) void {
    assert(mem_allocator == null);
    mem_allocator = allocator;
    mem_allocations = std.AutoHashMap(usize, usize).init(allocator);
    zstb_io = io;

    // stb image
    zstbi_image_MallocPtr = zstbiMalloc;
    zstbi_image_ReallocPtr = zstbiRealloc;
    zstbi_image_FreePtr = zstbiFree;
    // stb image resize
    zstbi_resize_MallocPtr = zstbirMalloc;
    zstbi_resize_FreePtr = zstbirFree;
    // stb image write
    zstbi_write_MallocPtr = zstbiMalloc;
    zstbi_write_ReallocPtr = zstbiRealloc;
    zstbi_write_FreePtr = zstbiFree;
}

pub fn deinit() void {
    assert(mem_allocator != null);
    assert(mem_allocations.?.count() == 0);

    setFlipVerticallyOnLoad(false);
    setFlipVerticallyOnWrite(false);

    mem_allocations.?.deinit();
    mem_allocations = null;
    mem_allocator = null;
}

pub const JpgWriteSettings = struct {
    quality: u32,
};

pub const ImageWriteFormat = union(enum) {
    png,
    jpg: JpgWriteSettings,
};

pub const ImageWriteError = error{
    CouldNotWriteImage,
};

pub const Image = struct {
    data: []u8,
    width: u32,
    height: u32,
    num_components: u32,
    bytes_per_component: u32,
    bytes_per_row: u32,
    is_hdr: bool,

    pub fn info(pathname: [:0]const u8) struct {
        is_supported: bool,
        width: u32,
        height: u32,
        num_components: u32,
    } {
        assert(mem_allocator != null);

        var w: c_int = 0;
        var h: c_int = 0;
        var c: c_int = 0;
        const is_supported = stbi_info(pathname, &w, &h, &c);
        return .{
            .is_supported = if (is_supported == 1) true else false,
            .width = @as(u32, @intCast(w)),
            .height = @as(u32, @intCast(h)),
            .num_components = @as(u32, @intCast(c)),
        };
    }

    pub fn loadFromFile(pathname: [:0]const u8, forced_num_components: u32) !Image {
        assert(mem_allocator != null);

        var width: u32 = 0;
        var height: u32 = 0;
        var num_components: u32 = 0;
        var bytes_per_component: u32 = 0;
        var bytes_per_row: u32 = 0;
        var is_hdr = false;

        const data = if (isHdr(pathname)) data: {
            var x: c_int = undefined;
            var y: c_int = undefined;
            var ch: c_int = undefined;
            const ptr = stbi_loadf(
                pathname,
                &x,
                &y,
                &ch,
                @as(c_int, @intCast(forced_num_components)),
            );
            if (ptr == null) return error.ImageInitFailed;

            num_components = if (forced_num_components == 0) @as(u32, @intCast(ch)) else forced_num_components;
            width = @as(u32, @intCast(x));
            height = @as(u32, @intCast(y));
            bytes_per_component = 2;
            bytes_per_row = width * num_components * bytes_per_component;
            is_hdr = true;

            // Convert each component from f32 to f16.
            var ptr_f16 = @as([*]f16, @ptrCast(ptr.?));
            const num = width * height * num_components;
            var i: u32 = 0;
            while (i < num) : (i += 1) {
                ptr_f16[i] = @as(f16, @floatCast(ptr.?[i]));
            }
            break :data @as([*]u8, @ptrCast(ptr_f16))[0 .. height * bytes_per_row];
        } else data: {
            var x: c_int = undefined;
            var y: c_int = undefined;
            var ch: c_int = undefined;
            const is_16bit = is16bit(pathname);
            const ptr = if (is_16bit) @as(?[*]u8, @ptrCast(stbi_load_16(
                pathname,
                &x,
                &y,
                &ch,
                @as(c_int, @intCast(forced_num_components)),
            ))) else stbi_load(
                pathname,
                &x,
                &y,
                &ch,
                @as(c_int, @intCast(forced_num_components)),
            );
            if (ptr == null) return error.ImageInitFailed;

            num_components = if (forced_num_components == 0) @as(u32, @intCast(ch)) else forced_num_components;
            width = @as(u32, @intCast(x));
            height = @as(u32, @intCast(y));
            bytes_per_component = if (is_16bit) 2 else 1;
            bytes_per_row = width * num_components * bytes_per_component;
            is_hdr = false;

            break :data @as([*]u8, @ptrCast(ptr))[0 .. height * bytes_per_row];
        };

        return Image{
            .data = data,
            .width = width,
            .height = height,
            .num_components = num_components,
            .bytes_per_component = bytes_per_component,
            .bytes_per_row = bytes_per_row,
            .is_hdr = is_hdr,
        };
    }

    pub fn loadFromMemory(data: []const u8, forced_num_components: u32) !Image {
        assert(mem_allocator != null);

        var width: u32 = 0;
        var height: u32 = 0;
        var num_components: u32 = 0;
        var bytes_per_component: u32 = 0;
        var bytes_per_row: u32 = 0;
        var is_hdr = false;

        const image_data = if (isHdrFromMem(data)) data: {
            var x: c_int = undefined;
            var y: c_int = undefined;
            var ch: c_int = undefined;
            const ptr = stbi_loadf_from_memory(
                data.ptr,
                @as(c_int, @intCast(data.len)),
                &x,
                &y,
                &ch,
                @as(c_int, @intCast(forced_num_components)),
            );
            if (ptr == null) return error.ImageInitFailed;

            num_components = if (forced_num_components == 0) @as(u32, @intCast(ch)) else forced_num_components;
            width = @as(u32, @intCast(x));
            height = @as(u32, @intCast(y));
            bytes_per_component = 2;
            bytes_per_row = width * num_components * bytes_per_component;
            is_hdr = true;

            // Convert each component from f32 to f16.
            var ptr_f16 = @as([*]f16, @ptrCast(ptr.?));
            const num = width * height * num_components;
            var i: u32 = 0;
            while (i < num) : (i += 1) {
                ptr_f16[i] = @as(f16, @floatCast(ptr.?[i]));
            }
            break :data @as([*]u8, @ptrCast(ptr_f16))[0 .. height * bytes_per_row];
        } else data: {
            var x: c_int = undefined;
            var y: c_int = undefined;
            var ch: c_int = undefined;
            const ptr = stbi_load_from_memory(
                data.ptr,
                @as(c_int, @intCast(data.len)),
                &x,
                &y,
                &ch,
                @as(c_int, @intCast(forced_num_components)),
            );
            if (ptr == null) return error.ImageInitFailed;

            num_components = if (forced_num_components == 0) @as(u32, @intCast(ch)) else forced_num_components;
            width = @as(u32, @intCast(x));
            height = @as(u32, @intCast(y));
            bytes_per_component = 1;
            bytes_per_row = width * num_components * bytes_per_component;

            break :data @as([*]u8, @ptrCast(ptr))[0 .. height * bytes_per_row];
        };

        return Image{
            .data = image_data,
            .width = width,
            .height = height,
            .num_components = num_components,
            .bytes_per_component = bytes_per_component,
            .bytes_per_row = bytes_per_row,
            .is_hdr = is_hdr,
        };
    }

    pub fn createEmpty(width: u32, height: u32, num_components: u32, args: struct {
        bytes_per_component: u32 = 0,
        bytes_per_row: u32 = 0,
    }) !Image {
        assert(mem_allocator != null);

        const bytes_per_component = if (args.bytes_per_component == 0) 1 else args.bytes_per_component;
        const bytes_per_row = if (args.bytes_per_row == 0)
            width * num_components * bytes_per_component
        else
            args.bytes_per_row;

        const size = height * bytes_per_row;

        const data = @as([*]u8, @ptrCast(zstbiMalloc(size)));
        @memset(data[0..size], 0);

        return Image{
            .data = data[0..size],
            .width = width,
            .height = height,
            .num_components = num_components,
            .bytes_per_component = bytes_per_component,
            .bytes_per_row = bytes_per_row,
            .is_hdr = false,
        };
    }

    pub fn resize(image: *const Image, new_width: u32, new_height: u32) !Image {
        assert(mem_allocator != null);

        // TODO: Add support for HDR images
        const layout: stbir_pixel_layout = switch (image.num_components) {
            1 => .STBIR_1CHANNEL,
            2 => .STBIR_2CHANNEL,
            3 => .STBIR_RGB,
            4 => .STBIR_RGBA,
            else => return error.InvalidComponentCount,
        };

        const new_bytes_per_row = new_width * image.num_components * image.bytes_per_component;
        const new_size = new_height * new_bytes_per_row;
        const new_data = @as([*]u8, @ptrCast(zstbiMalloc(new_size)));
        errdefer zstbiFree(new_data);
        const result = stbir_resize_uint8_linear(
            image.data.ptr,
            @as(c_int, @intCast(image.width)),
            @as(c_int, @intCast(image.height)),
            0,
            new_data,
            @as(c_int, @intCast(new_width)),
            @as(c_int, @intCast(new_height)),
            0,
            layout,
        );
        if (result == null) {
            return error.ResizeFailed;
        }
        return .{
            .data = new_data[0..new_size],
            .width = new_width,
            .height = new_height,
            .num_components = image.num_components,
            .bytes_per_component = image.bytes_per_component,
            .bytes_per_row = new_bytes_per_row,
            .is_hdr = image.is_hdr,
        };
    }

    pub fn writeToFile(
        image: Image,
        filename: [:0]const u8,
        image_format: ImageWriteFormat,
    ) ImageWriteError!void {
        assert(mem_allocator != null);

        const w = @as(c_int, @intCast(image.width));
        const h = @as(c_int, @intCast(image.height));
        const comp = @as(c_int, @intCast(image.num_components));
        const result = switch (image_format) {
            .png => stbi_write_png(filename.ptr, w, h, comp, image.data.ptr, 0),
            .jpg => |settings| stbi_write_jpg(
                filename.ptr,
                w,
                h,
                comp,
                image.data.ptr,
                @as(c_int, @intCast(settings.quality)),
            ),
        };
        // if the result is 0 then it means an error occured (per stb image write docs)
        if (result == 0) {
            return ImageWriteError.CouldNotWriteImage;
        }
    }

    pub fn writeToFn(
        image: Image,
        write_fn: *const fn (ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void,
        context: ?*anyopaque,
        image_format: ImageWriteFormat,
    ) ImageWriteError!void {
        assert(mem_allocator != null);

        const w = @as(c_int, @intCast(image.width));
        const h = @as(c_int, @intCast(image.height));
        const comp = @as(c_int, @intCast(image.num_components));
        const result = switch (image_format) {
            .png => stbi_write_png_to_func(write_fn, context, w, h, comp, image.data.ptr, 0),
            .jpg => |settings| stbi_write_jpg_to_func(
                write_fn,
                context,
                w,
                h,
                comp,
                image.data.ptr,
                @as(c_int, @intCast(settings.quality)),
            ),
        };
        // if the result is 0 then it means an error occured (per stb image write docs)
        if (result == 0) {
            return ImageWriteError.CouldNotWriteImage;
        }
    }

    pub fn deinit(image: *Image) void {
        stbi_image_free(image.data.ptr);
        image.* = undefined;
    }
};

pub const Gif = struct {
    data: []u8,
    width: u32,
    height: u32,
    frame_count: u32,
    num_components: u32,
    delays: ?[]u32,

    pub fn loadFromMemory(buffer: []const u8, req_comp: u32, with_delays: bool) !Gif {
        assert(mem_allocator != null);

        var x: c_int = undefined;
        var y: c_int = undefined;
        var z: c_int = undefined;
        var comp: c_int = undefined;
        var delays_ptr: [*]c_int = undefined;
        const data_ptr = stbi_load_gif_from_memory(
            buffer.ptr,
            @intCast(buffer.len),
            if (with_delays)
                &delays_ptr
            else
                null,
            &x,
            &y,
            &z,
            &comp,
            @intCast(req_comp),
        );
        if (data_ptr == null) {
            return error.GifInitFailed;
        }

        const width: u32 = @intCast(x);
        const height: u32 = @intCast(y);
        const frame_count: u32 = @intCast(z);
        const num_components: u32 =
            if (req_comp == 0)
                @intCast(comp)
            else
                req_comp;
        const delays: ?[]u32 = if (with_delays) blk: {
            const d: [*]u32 = @ptrCast(delays_ptr);
            break :blk d[0..frame_count];
        } else null;
        return .{
            .data = data_ptr.?[0 .. frame_count * height * width * num_components],
            .width = width,
            .height = height,
            .frame_count = frame_count,
            .num_components = num_components,
            .delays = delays,
        };
    }

    pub fn delayMs(gif: Gif, frame_index: u32) !u32 {
        if (frame_index >= gif.frame_count) {
            return error.InvalidFrameIndex;
        }
        if (gif.delays) |dels| {
            return dels[frame_index];
        } else {
            return error.NoDelays;
        }
    }

    pub fn frame(gif: Gif, frame_index: u32) ![]u8 {
        if (frame_index >= gif.frame_count) {
            return error.InvalidFrameIndex;
        }
        const stride: u32 = gif.width * gif.num_components * gif.height;
        return gif.data[frame_index * stride .. (frame_index + 1) * stride];
    }

    pub fn deinit(gif: *Gif) void {
        stbi_image_free(gif.data.ptr);
        if (gif.delays) |delays| {
            zstbiFree(delays.ptr);
        }
        gif.* = undefined;
    }
};

/// `pub fn setHdrToLdrScale(scale: f32) void`
pub const setHdrToLdrScale = stbi_hdr_to_ldr_scale;

/// `pub fn setHdrToLdrGamma(gamma: f32) void`
pub const setHdrToLdrGamma = stbi_hdr_to_ldr_gamma;

/// `pub fn setLdrToHdrScale(scale: f32) void`
pub const setLdrToHdrScale = stbi_ldr_to_hdr_scale;

/// `pub fn setLdrToHdrGamma(gamma: f32) void`
pub const setLdrToHdrGamma = stbi_ldr_to_hdr_gamma;

pub fn isHdr(filename: [:0]const u8) bool {
    return stbi_is_hdr(filename) != 0;
}

pub fn isHdrFromMem(buffer: []const u8) bool {
    return stbi_is_hdr_from_memory(buffer.ptr, @as(c_int, @intCast(buffer.len))) != 0;
}

pub fn is16bit(filename: [:0]const u8) bool {
    return stbi_is_16_bit(filename) != 0;
}

pub fn setFlipVerticallyOnLoad(should_flip: bool) void {
    stbi_set_flip_vertically_on_load(if (should_flip) 1 else 0);
}

pub fn setFlipVerticallyOnWrite(should_flip: bool) void {
    stbi_flip_vertically_on_write(if (should_flip) 1 else 0);
}

fn zstbiMalloc(size: usize) callconv(.c) ?*anyopaque {
    mem_mutex.lock(zstb_io) catch return null;
    defer mem_mutex.unlock(zstb_io);

    const mem = mem_allocator.?.alignedAlloc(
        u8,
        .fromByteUnits(mem_alignment),
        size,
    ) catch @panic("zstbi: out of memory");

    mem_allocations.?.put(@intFromPtr(mem.ptr), size) catch @panic("zstbi: out of memory");

    return mem.ptr;
}

fn zstbiRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    mem_mutex.lock(zstb_io) catch return null;
    defer mem_mutex.unlock(zstb_io);

    const old_size = if (ptr != null) mem_allocations.?.get(@intFromPtr(ptr.?)).? else 0;
    const old_mem = if (old_size > 0)
        @as([*]align(mem_alignment) u8, @ptrCast(@alignCast(ptr)))[0..old_size]
    else
        @as([*]align(mem_alignment) u8, undefined)[0..0];

    const new_mem = mem_allocator.?.realloc(old_mem, size) catch @panic("zstbi: out of memory");

    if (ptr != null) {
        const removed = mem_allocations.?.remove(@intFromPtr(ptr.?));
        std.debug.assert(removed);
    }

    mem_allocations.?.put(@intFromPtr(new_mem.ptr), size) catch @panic("zstbi: out of memory");

    return new_mem.ptr;
}

fn zstbiFree(maybe_ptr: ?*anyopaque) callconv(.c) void {
    if (maybe_ptr) |ptr| {
        mem_mutex.lock(zstb_io) catch return;
        defer mem_mutex.unlock(zstb_io);

        const size = mem_allocations.?.fetchRemove(@intFromPtr(ptr)).?.value;
        const mem = @as([*]align(mem_alignment) u8, @ptrCast(@alignCast(ptr)))[0..size];
        mem_allocator.?.free(mem);
    }
}

fn zstbirMalloc(size: usize, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    return zstbiMalloc(size);
}

fn zstbirFree(maybe_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    zstbiFree(maybe_ptr);
}

pub extern fn stbi_info(filename: [*:0]const u8, x: *c_int, y: *c_int, comp: *c_int) c_int;

pub extern fn stbi_load(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

pub extern fn stbi_load_16(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u16;

pub extern fn stbi_loadf(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]f32;

pub extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

pub extern fn stbi_load_16_from_memory(
    buffer: [*]const u16,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u16;

pub extern fn stbi_loadf_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]f32;

pub extern fn stbi_load_gif_from_memory(
    buffer: [*]const u8,
    len: c_int,
    delays: ?*[*]c_int,
    x: *c_int,
    y: *c_int,
    z: *c_int,
    comp: *c_int,
    req_comp: c_int,
) ?[*]u8;

pub extern fn stbi_image_free(image_data: ?[*]u8) void;

pub extern fn stbi_hdr_to_ldr_scale(scale: f32) void;
pub extern fn stbi_hdr_to_ldr_gamma(gamma: f32) void;
pub extern fn stbi_ldr_to_hdr_scale(scale: f32) void;
pub extern fn stbi_ldr_to_hdr_gamma(gamma: f32) void;

pub extern fn stbi_is_16_bit(filename: [*:0]const u8) c_int;
pub extern fn stbi_is_hdr(filename: [*:0]const u8) c_int;
pub extern fn stbi_is_hdr_from_memory(buffer: [*]const u8, len: c_int) c_int;

pub extern fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void;
pub extern fn stbi_flip_vertically_on_write(flag: c_int) void; // flag is non-zero to flip data vertically

pub extern fn stbir_resize_uint8_srgb(
    input_pixels: [*]const u8,
    input_w: c_int,
    input_h: c_int,
    input_stride_in_bytes: c_int,
    output_pixels: [*]u8,
    output_w: c_int,
    output_h: c_int,
    output_stride_in_bytes: c_int,
    pixel_type: stbir_pixel_layout,
) ?[*]u8;

pub extern fn stbir_resize_uint8_linear(
    input_pixels: [*]const u8,
    input_w: c_int,
    input_h: c_int,
    input_stride_in_bytes: c_int,
    output_pixels: [*]u8,
    output_w: c_int,
    output_h: c_int,
    output_stride_in_bytes: c_int,
    pixel_type: stbir_pixel_layout,
) ?[*]u8;

pub extern fn stbir_resize_float_linear(
    input_pixels: [*]const u8,
    input_w: c_int,
    input_h: c_int,
    input_stride_in_bytes: c_int,
    output_pixels: [*]f32,
    output_w: c_int,
    output_h: c_int,
    output_stride_in_bytes: c_int,
    pixel_type: stbir_pixel_layout,
) ?[*]f32;

pub extern fn stbir_resize(
    input_pixels: [*]const u8,
    input_w: c_int,
    input_h: c_int,
    input_stride_in_bytes: c_int,
    output_pixels: [*]u8,
    output_w: c_int,
    output_h: c_int,
    output_stride_in_bytes: c_int,
    pixel_type: stbir_pixel_layout,
    data_type: stbir_datatype,
    edge: stbir_edge,
    filter: stbir_filter,
) ?[*]u8;

pub extern fn stbi_write_png(
    filename: [*:0]const u8,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    stride_in_bytes: c_int,
) c_int;

pub extern fn stbi_write_bmp(
    filename: [*:0]const u8,
    x: c_int,
    y: c_int,
    comp: c_int,
    data: ?*const anyopaque,
) c_int;

pub extern fn stbi_write_tga(
    filename: [*:0]const u8,
    x: c_int,
    y: c_int,
    comp: c_int,
    data: ?*const anyopaque,
) c_int;

pub extern fn stbi_write_jpg(
    filename: [*:0]const u8,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    quality: c_int,
) c_int;

pub extern fn stbi_write_png_to_mem(
    pixels: [*]const u8,
    stride_bytes: c_int,
    x: c_int,
    y: c_int,
    n: c_int,
    out_len: *c_int,
) ?[*]u8;

pub extern fn stbi_write_png_to_func(
    func: stbi_write_func,
    context: ?*anyopaque,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    stride_in_bytes: c_int,
) c_int;

pub extern fn stbi_write_bmp_to_func(
    func: stbi_write_func,
    context: ?*anyopaque,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
) c_int;

pub extern fn stbi_write_tga_to_func(
    func: stbi_write_func,
    context: ?*anyopaque,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
) c_int;

pub extern fn stbi_write_hdr_to_func(
    func: stbi_write_func,
    context: ?*anyopaque,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const f32,
) c_int;

pub extern fn stbi_write_jpg_to_func(
    func: stbi_write_func,
    context: ?*anyopaque,
    x: c_int,
    y: c_int,
    comp: c_int,
    data: [*]const u8,
    quality: c_int,
) c_int;

pub const stbir_pixel_layout = enum(c_int) {
    STBIR_1CHANNEL = 1,
    STBIR_2CHANNEL = 2,
    STBIR_RGB = 3, // 3-chan, with order specified (for channel flipping)
    STBIR_BGR = 0, // 3-chan, with order specified (for channel flipping)
    STBIR_4CHANNEL = 5,

    STBIR_RGBA = 4, // alpha formats, where alpha is NOT premultiplied into color channels
    STBIR_BGRA = 6,
    STBIR_ARGB = 7,
    STBIR_ABGR = 8,
    STBIR_RA = 9,
    STBIR_AR = 10,

    STBIR_RGBA_PM = 11, // alpha formats, where alpha is premultiplied into color channels
    STBIR_BGRA_PM = 12,
    STBIR_ARGB_PM = 13,
    STBIR_ABGR_PM = 14,
    STBIR_RA_PM = 15,
    STBIR_AR_PM = 16,

    // STBIR_RGBA_NO_AW = 11, // alpha formats, where NO alpha weighting is applied at all!
    // STBIR_BGRA_NO_AW = 12, //   these are just synonyms for the _PM flags (which also do
    // STBIR_ARGB_NO_AW = 13, //   no alpha weighting). These names just make it more clear
    // STBIR_ABGR_NO_AW = 14, //   for some folks).
    // STBIR_RA_NO_AW = 15,
    // STBIR_AR_NO_AW = 16,
};

pub const stbir_edge = enum(c_int) {
    STBIR_EDGE_CLAMP = 0,
    STBIR_EDGE_REFLECT = 1,
    STBIR_EDGE_WRAP = 2, // this edge mode is slower and uses more memory
    STBIR_EDGE_ZERO = 3,
};

pub const stbir_filter = enum(c_int) {
    STBIR_FILTER_DEFAULT = 0, // use same filter type that easy-to-use API chooses
    STBIR_FILTER_BOX = 1, // A trapezoid w/1-pixel wide ramps, same result as box for integer scale ratios
    STBIR_FILTER_TRIANGLE = 2, // On upsampling, produces same results as bilinear texture filtering
    STBIR_FILTER_CUBICBSPLINE = 3, // The cubic b-spline (aka Mitchell-Netrevalli with B=1,C=0), gaussian-esque
    STBIR_FILTER_CATMULLROM = 4, // An interpolating cubic spline
    STBIR_FILTER_MITCHELL = 5, // Mitchell-Netrevalli filter with B=1/3, C=1/3
    STBIR_FILTER_POINT_SAMPLE = 6, // Simple point sampling
    STBIR_FILTER_OTHER = 7, // User callback specified
};

pub const stbir_datatype = enum(c_int) {
    STBIR_TYPE_UINT8 = 0,
    STBIR_TYPE_UINT8_SRGB = 1,
    STBIR_TYPE_UINT8_SRGB_ALPHA = 2, // alpha channel, when present, should also be SRGB (this is very unusual)
    STBIR_TYPE_UINT16 = 3,
    STBIR_TYPE_FLOAT = 4,
    STBIR_TYPE_HALF_FLOAT = 5,
};

pub const stbi_write_func = *const fn (context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void;

test "zstbi basic" {
    init(testing.io, testing.allocator);
    defer deinit();

    var im1 = try Image.createEmpty(8, 6, 4, .{});
    defer im1.deinit();

    try testing.expect(im1.width == 8);
    try testing.expect(im1.height == 6);
    try testing.expect(im1.num_components == 4);
}

test "zstbi resize" {
    init(testing.io, testing.allocator);
    defer deinit();

    var im1 = try Image.createEmpty(32, 32, 4, .{});
    defer im1.deinit();

    var im2 = try im1.resize(8, 6);
    defer im2.deinit();

    try testing.expect(im2.width == 8);
    try testing.expect(im2.height == 6);
    try testing.expect(im2.num_components == 4);
}

test "zstbi resize invalid components" {
    init(testing.io, testing.allocator);
    defer deinit();

    var im1 = try Image.createEmpty(8, 6, 0, .{});
    defer im1.deinit();

    try testing.expectError(error.InvalidComponentCount, im1.resize(8, 6));
}

test "zstbi write and load file" {
    init(testing.io, testing.allocator);
    defer deinit();

    const pth = try std.process.executableDirPathAlloc(zstb_io, testing.allocator);
    defer testing.allocator.free(pth);

    try std.process.setCurrentPath(testing.io, pth);

    var img = try Image.createEmpty(8, 6, 4, .{});
    defer img.deinit();

    try img.writeToFile("test_img.png", ImageWriteFormat.png);
    try img.writeToFile("test_img.jpg", .{ .jpg = .{ .quality = 80 } });

    var img_png = try Image.loadFromFile("test_img.png", 0);
    defer img_png.deinit();

    try testing.expect(img_png.width == img.width);
    try testing.expect(img_png.height == img.height);
    try testing.expect(img_png.num_components == img.num_components);

    var img_jpg = try Image.loadFromFile("test_img.jpg", 0);
    defer img_jpg.deinit();

    try testing.expect(img_jpg.width == img.width);
    try testing.expect(img_jpg.height == img.height);
    try testing.expect(img_jpg.num_components == 3); // RGB JPEG

    try std.Io.Dir.cwd().deleteFile(testing.io, "test_img.png");
    try std.Io.Dir.cwd().deleteFile(testing.io, "test_img.jpg");
}

test "zstbi gif load from memory" {
    init(testing.io, testing.allocator);
    defer deinit();

    const gif_bytes = [_]u8{
        71, 73, 70,  56, 57,  97, 2,   0,  2,  0,   129, 0,   0,  0,   0,  0,   0, 0, 255, 0,  255, 0, 255, 0, 0, 33, 255, 11, 78, 69,
        84, 83, 67,  65, 80,  69, 50,  46, 48, 3,   1,   0,   0,  0,   33, 249, 4, 0, 10,  0,  0,   0, 44,  0, 0, 0,  0,   2,  0,  2,
        0,  0,  8,   7,  0,   7,  8,   8,  0,  32,  32,  0,   33, 249, 4,  1,   5, 0, 4,   0,  44,  1, 0,   1, 0, 1,  0,   1,  0,  129,
        0,  0,  255, 0,  255, 0,  255, 0,  0,  255, 255, 255, 8,  4,   0,  7,   4, 4, 0,   59,
    };

    var gif = try Gif.loadFromMemory(&gif_bytes, 0, true);
    defer gif.deinit();

    try testing.expect(gif.width == 2);
    try testing.expect(gif.height == 2);
    try testing.expect(gif.frame_count == 2);
    try testing.expect(gif.num_components == 4);
    try testing.expect(gif.delays.?.len == 2);
    try testing.expectEqual(100, gif.delayMs(0));
    try testing.expectEqual(50, gif.delayMs(1));
    try testing.expectEqual(2 * 2 * 2 * 4, gif.data.len);
    try testing.expectEqual(2 * 2 * 4, (try gif.frame(0)).len);
    try testing.expectEqual(2 * 2 * 4, (try gif.frame(1)).len);
}

test "zstbi gif load without delays" {
    init(testing.io, testing.allocator);
    defer deinit();

    const gif_bytes = [_]u8{
        71, 73, 70,  56, 57,  97, 2,   0,  2,  0,   129, 0,   0,  0,   0,  0,   0, 0, 255, 0,  255, 0, 255, 0, 0, 33, 255, 11, 78, 69,
        84, 83, 67,  65, 80,  69, 50,  46, 48, 3,   1,   0,   0,  0,   33, 249, 4, 0, 10,  0,  0,   0, 44,  0, 0, 0,  0,   2,  0,  2,
        0,  0,  8,   7,  0,   7,  8,   8,  0,  32,  32,  0,   33, 249, 4,  1,   5, 0, 4,   0,  44,  1, 0,   1, 0, 1,  0,   1,  0,  129,
        0,  0,  255, 0,  255, 0,  255, 0,  0,  255, 255, 255, 8,  4,   0,  7,   4, 4, 0,   59,
    };

    var gif = try Gif.loadFromMemory(&gif_bytes, 0, false);
    defer gif.deinit();

    try testing.expect(gif.width == 2);
    try testing.expect(gif.height == 2);
    try testing.expect(gif.frame_count == 2);
    try testing.expect(gif.delays == null);
    try testing.expectError(error.NoDelays, gif.delayMs(0));
    try testing.expectEqual(@as(usize, 2 * 2 * 2 * 4), gif.data.len);
}

test "zstbi gif load from memory req_comp 3" {
    init(testing.io, testing.allocator);
    defer deinit();

    const gif_bytes = [_]u8{
        71, 73, 70,  56, 57,  97, 2,   0,  2,  0,   129, 0,   0,  0,   0,  0,   0, 0, 255, 0,  255, 0, 255, 0, 0, 33, 255, 11, 78, 69,
        84, 83, 67,  65, 80,  69, 50,  46, 48, 3,   1,   0,   0,  0,   33, 249, 4, 0, 10,  0,  0,   0, 44,  0, 0, 0,  0,   2,  0,  2,
        0,  0,  8,   7,  0,   7,  8,   8,  0,  32,  32,  0,   33, 249, 4,  1,   5, 0, 4,   0,  44,  1, 0,   1, 0, 1,  0,   1,  0,  129,
        0,  0,  255, 0,  255, 0,  255, 0,  0,  255, 255, 255, 8,  4,   0,  7,   4, 4, 0,   59,
    };

    var gif = try Gif.loadFromMemory(&gif_bytes, 3, true);
    defer gif.deinit();

    try testing.expect(gif.num_components == 3);
    try testing.expectEqual(@as(usize, 2 * 2 * 2 * 3), gif.data.len);
}

test "zstbi gif load invalid" {
    init(testing.io, testing.allocator);
    defer deinit();

    const garbage = [_]u8{ 1, 2, 3 };

    try testing.expectError(error.GifInitFailed, Gif.loadFromMemory(&garbage, 4, true));
}

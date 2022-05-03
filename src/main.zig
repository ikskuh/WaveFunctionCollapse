const std = @import("std");
const zero_graphics = @import("zero-graphics");
const s2s = @import("s2s");

const Application = @This();

const Rectangle = zero_graphics.Rectangle;
const Color = zero_graphics.Color;

allocator: std.mem.Allocator,
input_queue: *zero_graphics.Input,

rm: zero_graphics.ResourceManager,
r2: zero_graphics.Renderer2D,

screen_size: zero_graphics.Size,
mouse_pos: zero_graphics.Point = .{ .x = 0, .y = 0 },

tile_set_tex: *zero_graphics.ResourceManager.Texture,

tile_map: TileMap(?u8) = .{},
wave_function: TileMap(WaveFunction) = .{
    .tiles = undefined,
},
selected_draw_tile: u8 = 0,
tile_info: [256]TileInfo,
available_tiles: TileSet = TileSet.initEmpty(),

random: std.rand.DefaultPrng,
mode: Mode = .tile_editor,

pub fn init(app: *Application, allocator: std.mem.Allocator, input_queue: *zero_graphics.Input) !void {
    app.* = .{
        .allocator = allocator,
        .input_queue = input_queue,

        .r2 = undefined,
        .rm = undefined,
        .tile_set_tex = undefined,
        .tile_info = undefined,

        .screen_size = zero_graphics.Size.empty,
        .random = std.rand.DefaultPrng.init(@bitCast(u64, zero_graphics.milliTimestamp())),
    };

    app.rm = zero_graphics.ResourceManager.init(allocator);
    errdefer app.rm.deinit();

    app.r2 = try zero_graphics.Renderer2D.init(&app.rm, app.allocator);
    errdefer app.r2.deinit();

    app.tile_set_tex = try app.rm.createTexture(.ui, zero_graphics.ResourceManager.DecodePng{
        .data = @embedFile("../assets/base-tiles.png"),
    });

    app.tile_info = if (std.fs.cwd().openFile("source-tiles.dat", .{})) |*file| blk: {
        defer file.close();

        const neighbour_info_data: TileMap(?u8).Data = try s2s.deserialize(file.reader(), TileMap(?u8).Data);

        app.tile_map.tiles = neighbour_info_data;

        var tile_info = std.mem.zeroes([256]TileInfo);

        {
            var y: usize = 0;
            while (y < TileMapProto.height) : (y += 1) {
                var x: usize = 0;
                while (x < TileMapProto.width) : (x += 1) {
                    const inspected_index = neighbour_info_data[y][x] orelse continue;
                    const inspected = &tile_info[inspected_index];

                    app.available_tiles.set(inspected_index);

                    if (x > 0 and neighbour_info_data[y][x - 1] != null) {
                        const neighbour = neighbour_info_data[y][x - 1].?;
                        inspected.allowed_neighbours.left.set(neighbour);
                    }
                    if (x < TileMapProto.width - 1 and neighbour_info_data[y][x + 1] != null) {
                        const neighbour = neighbour_info_data[y][x + 1].?;
                        inspected.allowed_neighbours.right.set(neighbour);
                    }
                    if (y > 0 and neighbour_info_data[y - 1][x] != null) {
                        const neighbour = neighbour_info_data[y - 1][x].?;
                        inspected.allowed_neighbours.top.set(neighbour);
                    }
                    if (y < TileMapProto.height - 1 and neighbour_info_data[y + 1][x] != null) {
                        const neighbour = neighbour_info_data[y + 1][x].?;
                        inspected.allowed_neighbours.bottom.set(neighbour);
                    }
                }
            }
        }

        break :blk tile_info;
    } else |_| blk: {
        break :blk std.mem.zeroes([256]TileInfo);
    };

    for (app.wave_function.tiles) |*row| {
        for (row) |*tile| {
            // everything seems possible
            tile.* = .{ .interposition = app.available_tiles };
        }
    }
}

pub fn setupGraphics(app: *Application) !void {
    try app.rm.initializeGpuData();
}

pub fn resize(app: *Application, width: u15, height: u15) !void {
    app.screen_size = zero_graphics.Size{ .width = width, .height = height };
}

fn getTileSourceRectangle(index: u8) Rectangle {
    return Rectangle{
        .x = Tile.width * @as(i16, index % 8),
        .y = Tile.height * @as(i16, index / 8),
        .width = Tile.width,
        .height = Tile.height,
    };
}

fn getTileRectangle(x: usize, y: usize) Rectangle {
    return Rectangle{
        .x = @intCast(i16, Tile.width * x),
        .y = @intCast(i16, Tile.height * y),
        .width = Tile.width,
        .height = Tile.height,
    };
}

pub fn update(app: *Application) !bool {
    const tile_selection_rectangle = Rectangle{
        .x = @intCast(i16, Tile.width * (TileMapProto.width + 1)),
        .y = 0,
        .width = 8 * Tile.width,
        .height = 8 * Tile.height,
    };

    const tile_map_rectangle = Rectangle{
        .x = 0,
        .y = 0,
        .width = Tile.width * TileMapProto.width,
        .height = Tile.height * TileMapProto.height,
    };

    app.r2.reset();

    while (app.input_queue.pollEvent()) |event| {
        switch (event) {
            .quit => return false,
            .pointer_motion => |pt| app.mouse_pos = pt,
            .pointer_press => |pointer| switch (pointer) {
                .primary => {
                    if (tile_selection_rectangle.contains(app.mouse_pos)) {
                        const tx = @intCast(u32, app.mouse_pos.x - tile_selection_rectangle.x) / Tile.width;
                        const ty = @intCast(u32, app.mouse_pos.y - tile_selection_rectangle.y) / Tile.height;
                        app.selected_draw_tile = @intCast(u8, 8 * ty + tx);
                    } else {
                        //
                    }
                },
                .secondary => {},
            },
            .pointer_release => {},
            .text_input => {},
            .key_down => |key| switch (key) {
                .f1 => app.mode = .tile_editor,
                .f2 => app.mode = .pattern_editor,
                .f6 => if (app.mode == .pattern_editor) {
                    var file = try std.fs.cwd().createFile("source-tiles.dat", .{});
                    defer file.close();

                    try s2s.serialize(file.writer(), TileMap(?u8).Data, app.tile_map.tiles);

                    std.log.info("saved", .{});
                },
                .space => {
                    // collapse a single tile

                    var open_set = std.AutoArrayHashMap(Coordinate, TileSet).init(app.allocator);
                    defer open_set.deinit();

                    for (app.wave_function.tiles) |row, y| {
                        for (row) |cell, x| {
                            switch (cell) {
                                .collapsed => {},
                                .interposition => try open_set.put(Coordinate{ .x = x, .y = y }, undefined),
                            }
                        }
                    }

                    if (open_set.count() > 0) {
                        const initial_cell_pos = open_set.keys()[app.random.random().intRangeLessThan(usize, 0, open_set.count())];

                        const initial_cell = &app.wave_function.tiles[initial_cell_pos.y][initial_cell_pos.x];
                        std.debug.assert(initial_cell.* == .interposition);

                        var collapse_options = std.BoundedArray(u8, 256){};
                        {
                            var i: u32 = 0;
                            while (i < 256) : (i += 1) {
                                if (initial_cell.interposition.isSet(i)) {
                                    collapse_options.append(@truncate(u8, i)) catch unreachable;
                                }
                            }
                        }
                        if (collapse_options.len == 0) {
                            std.log.info("invalid collapse option: {},{}", .{ initial_cell_pos.x, initial_cell_pos.y });
                        } else {
                            const collapse_index = collapse_options.slice()[app.random.random().intRangeLessThan(usize, 0, collapse_options.len)];

                            try app.collapseCell(initial_cell_pos, collapse_index);
                        }
                    }
                },
                else => {},
            },
            .key_up => {},
        }
    }
    if (tile_map_rectangle.contains(app.mouse_pos)) {
        const tx = @intCast(u32, app.mouse_pos.x - tile_map_rectangle.x) / Tile.width;
        const ty = @intCast(u32, app.mouse_pos.y - tile_map_rectangle.y) / Tile.height;

        const visual_tile = &app.tile_map.tiles[ty][tx];
        const wave_tile = &app.wave_function.tiles[ty][tx];
        if (app.input_queue.mouse_state.get(.primary)) {
            switch (app.mode) {
                .pattern_editor => visual_tile.* = app.selected_draw_tile,
                .tile_editor => if (wave_tile.* == .interposition) {
                    if (wave_tile.interposition.isSet(app.selected_draw_tile)) {
                        try app.collapseCell(
                            Coordinate{ .x = tx, .y = ty },
                            app.selected_draw_tile,
                        );
                    }
                },
            }
        } else if (app.input_queue.mouse_state.get(.secondary)) {
            switch (app.mode) {
                .pattern_editor => visual_tile.* = null,
                .tile_editor => {}, //  wave_tile.* = .{ .interposition = app.available_tiles };
            }
        }
    }
    switch (app.mode) {
        .tile_editor => {
            for (app.wave_function.tiles) |row, y| {
                for (row) |interposition, x| {
                    const tile_rect = getTileRectangle(x, y);
                    switch (interposition) {
                        .collapsed => |index| {
                            try app.r2.drawPartialTexture(
                                tile_rect,
                                app.tile_set_tex,
                                getTileSourceRectangle(index),
                                null,
                            );
                        },
                        .interposition => |possibilities| {
                            //

                            var i: u32 = 0;
                            while (i < 256) : (i += 1) {
                                const index = @truncate(u8, i);

                                if (possibilities.isSet(index)) {
                                    var smol_rect = tile_rect;
                                    smol_rect.width = 4;
                                    smol_rect.height = 4;
                                    smol_rect.x += smol_rect.width * (index % 8);
                                    smol_rect.y += smol_rect.height * (index / 8);

                                    try app.r2.fillRectangle(smol_rect, Color.lime);
                                }
                            }

                            try app.r2.drawRectangle(tile_rect, Color.blue);
                        },
                    }
                }
            }
        },
        .pattern_editor => {
            for (app.tile_map.tiles) |row, y| {
                for (row) |maybe_tile_index, x| {
                    if (maybe_tile_index) |index| {
                        try app.r2.drawPartialTexture(
                            getTileRectangle(x, y),
                            app.tile_set_tex,
                            getTileSourceRectangle(index),
                            null,
                        );
                    }
                }
            }
        },
    }

    try app.r2.drawTexture(
        tile_selection_rectangle,
        app.tile_set_tex,
        null,
    );

    try app.r2.drawRectangle(
        Rectangle{
            .x = tile_selection_rectangle.x + Tile.width * (app.selected_draw_tile % 8),
            .y = tile_selection_rectangle.y + Tile.height * (app.selected_draw_tile / 8),
            .width = Tile.width,
            .height = Tile.height,
        },
        Color.red,
    );

    try app.r2.drawLine(
        app.mouse_pos.x - 10,
        app.mouse_pos.y,
        app.mouse_pos.x + 10,
        app.mouse_pos.y,
        Color.red,
    );
    try app.r2.drawLine(
        app.mouse_pos.x,
        app.mouse_pos.y - 10,
        app.mouse_pos.x,
        app.mouse_pos.y + 10,
        Color.red,
    );

    return true;
}

const Coordinate = struct {
    x: usize,
    y: usize,

    fn mutX(self: @This(), dx: i8) @This() {
        var copy = self;
        copy.x = @intCast(usize, @intCast(isize, copy.x) + dx);
        return copy;
    }
    fn mutY(self: @This(), dy: i8) @This() {
        var copy = self;
        copy.y = @intCast(usize, @intCast(isize, copy.y) + dy);
        return copy;
    }
};

fn collapseCell(app: *Application, pos: Coordinate, tile_index: u8) !void {
    const initial_cell_pos = pos;
    const initial_cell = &app.wave_function.tiles[initial_cell_pos.y][initial_cell_pos.x];

    if (initial_cell.* != .interposition)
        return error.AlreadyCollapsed;
    if (!initial_cell.interposition.isSet(tile_index))
        return error.InvalidTileIndex;

    var open_set = std.AutoArrayHashMap(Coordinate, TileSet).init(app.allocator);
    defer open_set.deinit();

    initial_cell.* = .{ .collapsed = tile_index };

    var initial_info = tileSetForIndex(tile_index);

    try open_set.put(initial_cell_pos, initial_info);

    while (open_set.count() > 0) {
        const cell_position = open_set.keys()[0];
        //const new_mask = open_set.values()[0];
        _ = open_set.swapRemove(cell_position);

        const observed_cell = &app.wave_function.tiles[cell_position.y][cell_position.x];

        const Pair = struct {
            pos: Coordinate,
            mask: TileSet,

            fn getNeighbourMask(info: [256]TileInfo, func: WaveFunction, comptime neighbour: []const u8) TileSet {
                switch (func) {
                    .collapsed => |i| return @field(info[i].allowed_neighbours, neighbour),
                    .interposition => |possibilities| {
                        var result = TileSet.initEmpty();

                        var i: u32 = 0;
                        while (i < 256) : (i += 1) {
                            if (possibilities.isSet(i)) {
                                result.setUnion(@field(info[i].allowed_neighbours, neighbour));
                            }
                        }

                        return result;
                    },
                }
            }
        };

        var neighbours = std.BoundedArray(Pair, 4){};
        {
            if (cell_position.x > 0) {
                try neighbours.append(Pair{
                    .pos = cell_position.mutX(-1),
                    .mask = Pair.getNeighbourMask(app.tile_info, observed_cell.*, "left"),
                });
            }
            if (cell_position.y > 0) {
                try neighbours.append(Pair{
                    .pos = cell_position.mutY(-1),
                    .mask = Pair.getNeighbourMask(app.tile_info, observed_cell.*, "top"),
                });
            }
            if (cell_position.x < TileMapProto.width - 1) {
                try neighbours.append(Pair{
                    .pos = cell_position.mutX(1),
                    .mask = Pair.getNeighbourMask(app.tile_info, observed_cell.*, "right"),
                });
            }
            if (cell_position.y < TileMapProto.height - 1) {
                try neighbours.append(Pair{
                    .pos = cell_position.mutY(1),
                    .mask = Pair.getNeighbourMask(app.tile_info, observed_cell.*, "bottom"),
                });
            }
        }

        std.log.info("observe {},{} with {} neighbours", .{ cell_position.x, cell_position.y, neighbours.len });

        for (neighbours.slice()) |pair| {
            const neighbour_pos = pair.pos;
            const neighbour_cell = &app.wave_function.tiles[neighbour_pos.y][neighbour_pos.x];

            if (neighbour_cell.* != .interposition)
                continue;

            const interposition = &neighbour_cell.interposition;

            const previous = interposition.*;

            interposition.setIntersection(pair.mask);

            const count = interposition.count();

            if (previous.count() != count) {
                const new_state = interposition.*;

                if (count == 1) {
                    // collapse cell

                    neighbour_cell.* = .{ .collapsed = @intCast(u8, new_state.findFirstSet().?) };
                }

                const gop = try open_set.getOrPut(neighbour_pos);
                if (gop.found_existing) {
                    gop.value_ptr.setIntersection(new_state);
                } else {
                    gop.value_ptr.* = new_state;
                }
            } else {
                // unchanged
            }
        }
    }
}

pub fn render(app: *Application) !void {
    zero_graphics.gles.clear(zero_graphics.gles.COLOR_BUFFER_BIT);

    app.r2.render(app.screen_size);
}

pub fn teardownGraphics(app: *Application) void {
    app.rm.destroyGpuData();
}

pub fn deinit(app: *Application) void {
    app.r2.deinit();
    app.rm.deinit();
}

const Tile = struct {
    pub const width = 32;
    pub const height = 32;

    index: u8,
};

const TileMapProto = struct {
    pub const width = 30;
    pub const height = 20;
};

pub fn TileMap(comptime T: type) type {
    return struct {
        pub const Data = [TileMapProto.height][TileMapProto.width]T;
        pub const width = TileMapProto.width;
        pub const height = TileMapProto.height;

        tiles: Data = std.mem.zeroes(Data),
    };
}

const TileSet = std.StaticBitSet(256);

const TileNeighbourData = struct {
    top: TileSet = TileSet.initEmpty(), // y-1
    left: TileSet = TileSet.initEmpty(), // x-1
    right: TileSet = TileSet.initEmpty(), // x+1
    bottom: TileSet = TileSet.initEmpty(), // y+1
};

const TileInfo = struct {
    allowed_neighbours: TileNeighbourData,
};

const WaveFunction = union(enum) {
    collapsed: u8,
    interposition: TileSet,
};

fn tileSetForIndex(index: u8) TileSet {
    var set = TileSet.initEmpty();
    set.set(index);
    return set;
}

const Mode = enum {
    tile_editor,
    pattern_editor,
};

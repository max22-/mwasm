const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const types = @import("types.zig");
const VectorType = types.VectorType;
const ValueType = types.ValueType;
const ResultType = types.ResultType;
const FunctionType = types.FunctionType;
const Expr = types.Expr;
const Function = types.Function;
const Memory = types.Memory;
const ExportDesc = types.ExportDesc;
const Instruction = @import("instructions.zig").Instruction;

const Self = @This();

allocator: Allocator,
function_types: ArrayList(FunctionType),
functions: ArrayList(Function),
mems: ArrayList(Memory),
exports: ArrayList(Export),

pub const ModuleError = error{
    InvalidWasmBinary,
    InvalidMagic,
    InvalidVersion,
};

const SectionId = enum {
    custom,
    type,
    import,
    function,
    table,
    memory,
    global,
    @"export",
    start,
    element,
    code,
    data,
    dataCount,
};

const Export = struct {
    name: []u8,
    desc: ExportDesc,
    allocator: Allocator,

    fn deinit(self: *Export) void {
        self.allocator.free(self.name);
    }
};

pub fn init(allocator: Allocator) Self {
    return Self{
        .allocator = allocator,
        .function_types = ArrayList(FunctionType).init(allocator),
        .functions = ArrayList(Function).init(allocator),
        .mems = ArrayList(Memory).init(allocator),
        .exports = ArrayList(Export).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    for (self.function_types.items) |ftype| {
        ftype.params.deinit();
        ftype.results.deinit();
    }
    self.function_types.deinit();
    for (self.functions.items) |*f| {
        f.deinit();
    }
    self.functions.deinit();
    for (self.mems.items) |*m| {
        m.deinit();
    }
    self.mems.deinit();
    for (self.exports.items) |*e| {
        e.deinit();
    }
    self.exports.deinit();
}

pub fn load(self: *Self, w: anytype) !void {
    try checkMagic(w);
    try checkVersion(w);
    try readSections(self, w);
}

fn checkMagic(w: anytype) !void {
    if (!(w.isBytes("\x00asm") catch {
        return ModuleError.InvalidWasmBinary;
    })) {
        return ModuleError.InvalidMagic;
    }
}

fn checkVersion(w: anytype) !void {
    const version = try w.readInt(u32, .little);
    if (version != 1) {
        return ModuleError.InvalidVersion;
    }
}

fn readValueType(w: anytype) !ValueType {
    const b = w.readByte() catch return ModuleError.InvalidWasmBinary;
    switch (b) {
        0x7f => return ValueType{ .number_type = .i32 },
        0x7e => return ValueType{ .number_type = .i64 },
        0x7d => return ValueType{ .number_type = .f32 },
        0x7c => return ValueType{ .number_type = .f64 },
        0x7b => return ValueType{ .vector_type = VectorType{} },
        0x70 => return ValueType{ .ref_type = .funcref },
        0x6f => return ValueType{ .ref_type = .externref },
        else => return ModuleError.InvalidWasmBinary,
    }
}

fn readResultType(self: *Self, w: anytype) !ResultType {
    const n = std.leb.readULEB128(u32, w) catch return ModuleError.InvalidWasmBinary;
    var result = ResultType.init(self.allocator);
    errdefer result.deinit();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try result.append(try readValueType(w));
    }
    return result;
}

fn readTypeSection(self: *Self, w: anytype) !void {
    const n = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = w.readByte() catch return ModuleError.InvalidWasmBinary;
        if (b != 0x60) return ModuleError.InvalidWasmBinary;
        const params = try self.readResultType(w);
        errdefer params.deinit();
        const results = try self.readResultType(w);
        errdefer results.deinit();
        self.function_types.append(FunctionType{
            .params = params,
            .results = results,
        }) catch {
            return ModuleError.InvalidWasmBinary;
        };
    }
}

fn readFunctionSection(self: *Self, w: anytype) !void {
    const n = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const idx = w.readByte() catch return ModuleError.InvalidWasmBinary;
        try self.functions.append(Function.init(self.allocator, idx));
        std.debug.print("function index: 0x{x}\n", .{idx});
    }
}

fn readMemorySection(self: *Self, w: anytype) !void {
    const n = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
    std.debug.print("{} memories\n", .{n});
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = w.readByte() catch return ModuleError.InvalidWasmBinary;
        switch (b) {
            0x00 => {
                const min_size = w.readByte() catch return ModuleError.InvalidWasmBinary;
                try self.mems.append(try Memory.init(self.allocator, min_size, null));
                std.debug.print("min = {}\n", .{min_size});
            },
            0x01 => {
                const min_size = w.readByte() catch return ModuleError.InvalidWasmBinary;
                const max_size = w.readByte() catch return ModuleError.InvalidWasmBinary;
                std.debug.print("min = {}, max = {}\n", .{ min_size, max_size });
            },
            else => return ModuleError.InvalidWasmBinary,
        }
    }
}

fn readExportSection(self: *Self, w: anytype) !void {
    const n = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
    std.debug.print("{} export(s)\n", .{n});
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const len = w.readByte() catch return ModuleError.InvalidWasmBinary;
        const name = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(name);
        w.readNoEof(name) catch return ModuleError.InvalidWasmBinary;
        const desc = w.readByte() catch return ModuleError.InvalidWasmBinary;
        if (desc > 3) return ModuleError.InvalidWasmBinary;
        const idx = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
        std.debug.print("- {s} {} {}\n", .{
            name,
            @as(ExportDesc, @enumFromInt(desc)),
            idx,
        });
        try self.exports.append(Export{
            .name = name,
            .desc = @as(ExportDesc, @enumFromInt(desc)),
            .allocator = self.allocator,
        });
    }
}

fn readLocals(allocator: Allocator, w: anytype) !ArrayList(ValueType) {
    var result = ArrayList(ValueType).init(allocator);
    errdefer result.deinit();
    const n = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const n2 = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
        const value_type = try readValueType(w);
        var j: i32 = 0;
        while (j < n2) : (j += 1) {
            try result.append(value_type);
        }
    }
    return result;
}

fn readExpr(allocator: Allocator, w: anytype) !Expr {
    var e = Expr.init(allocator);
    errdefer e.deinit();
    while (true) {
        const b = try Instruction.read(w);
        try e.append(b);
        if (b == Instruction.end) break;
    }
    return e;
}

fn readCodeSection(self: *Self, w: anytype) !void {
    const n = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
    std.debug.print("{} code entries\n", .{n});
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i >= self.functions.items.len) {
            return ModuleError.InvalidWasmBinary;
        }
        const size: u32 = std.leb.readUleb128(u32, w) catch return ModuleError.InvalidWasmBinary;
        const locals = try readLocals(self.allocator, w);
        errdefer locals.deinit();
        const expr = try readExpr(self.allocator, w);
        errdefer expr.deinit();
        self.functions.items[i].locals = locals;
        self.functions.items[i].body = expr;

        std.debug.print("{}- size={} expr={any}\n", .{ i, size, expr });
    }
}

fn readSections(self: *Self, w: anytype) !void {
    while (true) {
        const id = w.readByte() catch break;
        if (id > 12) {
            std.debug.print("error: id = {}\n", .{id});
            return ModuleError.InvalidWasmBinary;
        }
        const section_id = @as(SectionId, @enumFromInt(id));
        std.debug.print("section: {}\n", .{section_id});
        const size = try std.leb.readUleb128(u32, w);
        switch (section_id) {
            .type => try self.readTypeSection(w),
            .function => try self.readFunctionSection(w),
            .memory => try self.readMemorySection(w),
            .@"export" => try self.readExportSection(w),
            .code => try self.readCodeSection(w),
            else => w.skipBytes(size, .{}) catch {
                return ModuleError.InvalidWasmBinary;
            },
        }
    }
}

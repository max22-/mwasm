const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Self = @This();

allocator: Allocator,
function_types: ArrayList(FunctionType),
functions: ArrayList(Function),

const ModuleError = error{
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

const NumberType = enum {
    i32,
    i64,
    f32,
    f64,
};

const VectorType = struct {};

const RefType = enum {
    funcref,
    externref,
};

const ValueTypeTag = enum {
    number_type,
    vector_type,
    ref_type,
};

const ValueType = union(ValueTypeTag) {
    number_type: NumberType,
    vector_type: VectorType,
    ref_type: RefType,
};

const ResultType = ArrayList(ValueType);

const FunctionType = struct {
    params: ArrayList(ValueType),
    results: ArrayList(ValueType),
};

const Expr = ArrayList(u8);

const Function = struct {
    type: usize,
    locals: ArrayList(ValueType),
    body: Expr,

    fn init(allocator: Allocator, @"type": usize) Function {
        return Function{
            .type = @"type",
            .locals = ArrayList(ValueType).init(allocator),
            .body = Expr.init(allocator),
        };
    }

    fn deinit(self: *Function) void {
        self.locals.deinit();
        self.body.deinit();
    }
};

pub fn init(allocator: Allocator) Self {
    return Self{
        .allocator = allocator,
        .function_types = ArrayList(FunctionType).init(allocator),
        .functions = ArrayList(Function).init(allocator),
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

fn readSections(self: *Self, w: anytype) !void {
    while (true) {
        const id = w.readByte() catch break;
        if (id > 12) {
            return ModuleError.InvalidWasmBinary;
        }
        const section_id = @as(SectionId, @enumFromInt(id));
        std.debug.print("section: {}\n", .{section_id});
        const size = try std.leb.readUleb128(u32, w);
        switch (section_id) {
            .type => try readTypeSection(self, w),
            .function => try readFunctionSection(self, w),
            else => w.skipBytes(size, .{}) catch {
                return ModuleError.InvalidWasmBinary;
            },
        }
    }
}

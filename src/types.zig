const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Instruction = @import("instructions.zig").Instruction;

pub const NumberType = enum {
    i32,
    i64,
    f32,
    f64,
};

pub const VectorType = struct {};

pub const RefType = enum {
    funcref,
    externref,
};

const ValueTypeTag = enum {
    number_type,
    vector_type,
    ref_type,
};

pub const ValueType = union(ValueTypeTag) {
    number_type: NumberType,
    vector_type: VectorType,
    ref_type: RefType,
};

pub const ResultType = ArrayList(ValueType);

pub const FunctionType = struct {
    params: ArrayList(ValueType),
    results: ArrayList(ValueType),
};

pub const Expr = ArrayList(Instruction);

pub const Function = struct {
    type: usize,
    locals: ArrayList(ValueType),
    body: Expr,

    pub fn init(allocator: Allocator, @"type": usize) Function {
        return Function{
            .type = @"type",
            .locals = ArrayList(ValueType).init(allocator),
            .body = Expr.init(allocator),
        };
    }

    pub fn deinit(self: *Function) void {
        self.locals.deinit();
        self.body.deinit();
    }
};

pub const Memory = struct {
    min_size: usize,
    max_size: ?usize,
    mem: []u8,
    allocator: Allocator,

    const page_size = 65536;

    pub fn init(allocator: Allocator, min_size: usize, max_size: ?usize) !Memory {
        return Memory{
            .min_size = min_size,
            .max_size = max_size,
            .mem = try allocator.alloc(u8, min_size * page_size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.mem);
    }
};

pub const ExportDesc = enum {
    function,
    table,
    mem,
    global,
};

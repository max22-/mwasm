const ModuleError = @import("module.zig").ModuleError;
const std = @import("std");

const InstructionTag = enum(u8) {
    end = 0x0b,
    local_get = 0x20,
    i32_add = 0x6a,
};

pub const Instruction = union(InstructionTag) {
    end: void,
    local_get: u32,
    i32_add: void,

    pub fn read(r: anytype) !Instruction {
        const b = r.readByte() catch return ModuleError.InvalidWasmBinary;
        switch (b) {
            0x0b => return Instruction.end,
            0x20 => {
                const n = std.leb.readUleb128(u32, r) catch return ModuleError.InvalidWasmBinary;
                return Instruction{ .local_get = n };
            },
            0x6a => return Instruction.i32_add,
            else => return ModuleError.InvalidWasmBinary,
        }
        //inline for (@typeInfo(InstructionTag).@"enum".fields) |field| {
        //    if (field.value == b) {
        //        return @unionInit(
        //            Instruction,
        //            field.name,
        //            {},
        //        );
        //    }
        //}
        //return ModuleError.InvalidWasmBinary;
    }
};

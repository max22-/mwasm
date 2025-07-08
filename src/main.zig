const std = @import("std");
const mwasm = @import("mwasm");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    const exec_name = args.next().?;
    const wasm_path = args.next();
    if (wasm_path == null) {
        std.debug.print("usage: {s} file.wasm\n", .{exec_name});
        return 1;
    }
    const wasm_bin = std.fs.cwd().openFile(wasm_path.?, .{}) catch {
        std.debug.print("failed to open {s}\n", .{wasm_path.?});
        return 1;
    };
    defer wasm_bin.close();

    var module = mwasm.Module.init(allocator);
    defer module.deinit();
    try module.load(wasm_bin.reader());
    std.debug.print("{}\n", .{module});

    return 0;
}

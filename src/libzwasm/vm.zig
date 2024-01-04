const std = @import("std");

const wasm = @import("wasm.zig");
const wat = @import("wat.zig");

const Allocator = std.mem.Allocator;

const STACK_SIZE = 16 * 1024;

const Value = union(enum) {
    vec128: [16]u8,
    int32: u32,
    float32: f32,
    int64: u64,
    float64: f64,
    funcref: usize,
    externref: struct {
        module: []const u8,
        func: []const u8,
    },
};

pub const Error = error{
    StackOverflow,
    StackUnderflow,
    BadInstruction,
    BadType,
    FunctionNotFound,
    ModuleNotFound,
} || Allocator.Error || wasm.WasmError;

const CallFrame = struct {
    bytes: []const u8,
    ip: usize,
    locals: []Value,
};

const CALL_FRAME_LIMIT = 1024;

pub const EnvironmentFunction = *const fn (*VirtualMachine) callconv(.C) c_int;

pub const VirtualMachine = struct {
    stack: *[STACK_SIZE]Value,
    stack_top: [*]Value,
    stack_idx: usize,
    call_frame: *[CALL_FRAME_LIMIT]CallFrame,
    call_top: [*]CallFrame,
    call_idx: usize,
    memory: std.ArrayList(u8),
    allocator: Allocator,
    environment: std.StringHashMap(std.StringHashMap(EnvironmentFunction)),
    funcs: std.ArrayList([]const u8),
    exported: std.StringHashMap(u32),
    trapped: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, binary: []const u8) !Self {
        const stack = try allocator.create([STACK_SIZE]Value);
        errdefer allocator.destroy(stack);

        const calls = try allocator.create([CALL_FRAME_LIMIT]CallFrame);
        errdefer allocator.destroy(calls);

        const module = wasm.WasmModule.init(binary, allocator);
        _ = module;

        const funcs = std.ArrayList([]const u8).init(allocator);
        errdefer funcs.deinit();

        return Self{
            .stack = stack,
            .stack_top = stack,
            .stack_idx = 0,
            .memory = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
            .call_frame = calls,
            .call_top = calls,
            .call_idx = 0,
            .environment = std.StringHashMap(std.StringHashMap(EnvironmentFunction)).init(allocator),
            .funcs = funcs,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.destroy(self.stack);
        self.memory.deinit();
    }

    pub fn loadEnvironmentFunction(self: *Self, module: []const u8, func: []const u8, f: EnvironmentFunction) Error!void {
        var modMaybe = self.environment.getPtr(module);
        if (modMaybe) |mod| {
            try mod.put(func, f);
        } else {
            return Error.ModuleNotFound;
        }
    }

    fn push(self: *Self, value: Value) Error!void {
        if (self.stack_idx == STACK_SIZE) {
            return Error.StackOverflow;
        }
        self.stack_top.* = value;
        self.stack_top += 1;
        self.stack_idx += 1;
    }

    fn pop(self: *Self) Error!Value {
        if (self.stack_idx == 0) {
            return Error.StackUnderflow;
        }

        const value = self.stack_top.*;
        self.stack_top -= 1;
        self.stack_idx -= 1;

        return value;
    }
};

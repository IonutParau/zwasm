const std = @import("std");

const Allocator = std.mem.Allocator;

const memargs = struct {
    offsetArg: u32,
    alignArg: u32,
};

const id = union(enum) {
    idx: usize,
    label: []const u8,
};

pub const NodeKind = union(enum) {
    module,
    function,
    typedef,
    globals,
    data,
    memory,
    exportDef,
    importDef,
    drop,
    inf,
    nan,
    nanPayload: []const u8,
    id: []const u8,
    string: []const u8,
    name: []const u8, // string but must be valid UTF-8
    float: f64,
    integer: u64,

    // Control flow
    // TODO: im lazy

    // Memory / Data
    memory_size,
    memory_grow,
    memory_fill,
    memory_copy,
    memory_init: id,
    data_drop: id,

    // i32 ops
    i32_type,
    i32_load: memargs,
    i32_load8_s: memargs,
    i32_load8_u: memargs,
    i32_store: memargs,
    i32_store8: memargs,
    i32_store16: memargs,
    i32_const: u32,
    i32_clz,
    i32_ctz,
    i32_popcnt,
    i32_add,
    i32_sub,
    i32_mult,
    i32_div_s,
    i32_div_u,
    i32_rem_s,
    i32_rem_u,
    i32_and,
    i32_or,
    i32_xor,
    i32_shl,
    i32_shr_s,
    i32_shr_u,
    i32_rotl,
    i32_rotr,
    i32_wrap_i64,
    i32_trunc_f32_s,
    i32_trunc_f32_u,
    i32_trunc_f64_s,
    i32_trunc_f64_u,
    i32_trunc_sat_f32_s,
    i32_trunc_sat_f32_u,
    i32_trunc_sat_f64_s,
    i32_trunc_sat_f64_u,
    i32_reinterpret_f32,
    i32_extend8_s,
    i32_extend16_s,
};

pub const Node = struct {
    kind: NodeKind,
    source: usize,
    idx: usize,

    const Self = @This();

    pub fn init(kind: NodeKind, source: usize, idx: usize) Self {
        return Self{
            .kind = kind,
            .source = source,
            .idx = idx,
        };
    }

    pub fn child(self: *const Self, allocator: Allocator) ![]const Node {
        _ = allocator;
        _ = self;
    }

    pub fn size(self: *const Self) usize {
        _ = self;
        @compileError("Not implemented yet");
    }
};

pub const Parser = struct {};

pub const FlatAST = []const Node;

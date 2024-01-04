const std = @import("std");

const Allocator = std.mem.Allocator;

pub const WasmError = error{ InvalidByte, AbruptStop, MalformedName } || Allocator.Error;

pub const NumType = union(enum) {
    int32,
    float32,
    int64,
    float64,
};
pub const RefType = union(enum) {
    funcref,
    externref,
};
pub const ValueType = union(enum) {
    num: NumType,
    vec,
    ref,
};
pub const ResultType = std.ArrayList(ValueType);
pub const FunctionType = struct {
    inputs: ResultType,
    outputs: ResultType,
};

pub const Locals = struct {
    count: u32,
    t: ValueType,
};

pub const Sections = struct {
    pub const Custom = struct {
        name: std.ArrayList(u8),
        bytes: []const u8,
    };

    pub const Type = struct {
        types: std.ArrayList(FunctionType),
    };

    pub const Function = struct {
        functypes: std.ArrayList(u32),
    };

    pub const Code = struct {
        locals: std.ArrayList(Locals),
        code: []const u8,
    };
};

const byterev_lookup = [16]u8{
    0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe,
    0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf,
};

pub fn reverseByte(byte: u8) u8 {
    return (byterev_lookup[byte & 0b1111] << 4) | byterev_lookup[byte >> 4];
}

pub fn wasmIntToNative(x: anytype) @TypeOf(x) {
    const endian = @import("builtin").target.cpu.arch.endian();

    const T = @TypeOf(x);
    const SIZE = @sizeOf(T);

    switch (endian) {
        .Little => return x,
        .Big => {}, // continue
    }

    const stack_buffer: [SIZE]u8 = @bitCast(x);
    const output_buffer: [SIZE]u8 = undefined;

    for (stack_buffer, 0..) |byte, i| {
        const j = SIZE - i - 1;

        const rev_byte = reverseByte(byte);

        output_buffer[j] = rev_byte;
    }

    return @bitCast(output_buffer);
}

pub const WasmModule = struct {
    binary: []const u8,
    i: usize,
    allocator: Allocator,

    pub fn init(binary: []const u8, allocator: Allocator) WasmModule {
        return WasmModule{
            .binary = binary,
            .allocator = allocator,
        };
    }

    pub fn peek(self: *const WasmModule, comptime T: type) WasmError!T {
        const remaining = self.binary.len - self.i;
        const size = @sizeOf(T);
        if (remaining < size) {
            return WasmError.AbruptStop;
        }

        var reverse = false;

        const typeInfo: std.builtin.Type = @typeInfo(T);
        switch (typeInfo) {
            .Int => {
                // Uh-oh, if endianness conflicts we would get random junk!
                // Best we check

                const endianness: std.builtin.Endian = @import("builtin").target.cpu.arch.endian();

                switch (endianness) {
                    .Little => {}, // All is good
                    .Big => {
                        // We need to flip this.
                        reverse = true;
                    },
                }
            },
        }

        const buffer = self.binary[self.i .. self.i + size];
        const stack_buffer: [size]u8 = undefined;

        if (reverse) {
            var i: usize = size - 1;
            while (true) {
                var j = size - i - 1;
                i -= 1;

                var original_byte = stack_buffer[j];
                var reversed = reverseByte(original_byte);
                stack_buffer[i] = reversed;
                if (i == 0) break; // To not get undefined behavior
            }
        } else {
            for (buffer, 0..) |b, i| {
                stack_buffer[i] = b;
            }
        }

        const val: T = @bitCast(stack_buffer);
        return val;
    }

    pub fn next(self: *WasmModule, comptime T: type) WasmError!T {
        const v = try self.peek(T);
        self.i += @sizeOf(T);
        return v;
    }

    pub fn nextVector(self: *WasmModule, comptime T: type) WasmError!std.ArrayList(T) {
        const len = try self.next(u32);
        var list = try std.ArrayList(T).initCapacity(self.allocator, len);
        errdefer list.deinit();

        var i: usize = 0;
        while (i < len) : (i += 1) {
            try list.append(try self.next(T));
        }

        return list;
    }

    pub fn nextName(self: *WasmModule) WasmError!std.ArrayList(u8) {
        const name = try self.nextVector(u8);

        if (!std.unicode.utf8ValidateSlice(name.items)) {
            return WasmError.MalformedName;
        }

        return name;
    }

    // The WasmModule given is a
    // ssigned as its binary to the code inside the section
    pub fn parseSection(self: *WasmModule, comptime T: type, id: usize, comptime parser: fn (WasmModule) WasmError!T) WasmError!?T {
        const N = try self.peek(u8);
        if (N != id) return null; // Not the section we're looking for
        _ = try self.next(u8);

        const size = try self.next(u32);
        const buffer = self.binary[self.i .. self.i + size];
        const submodule = WasmModule.init(buffer, self.allocator);
        const parsed = try parser(submodule);
        self.i += size;

        return parsed;
    }

    fn customSectionParser(module: WasmModule) WasmError!Sections.Custom {
        const name = try module.nextName();
        const byteoff = name.items.len + @sizeOf(u32);
        const bytes = module.binary[byteoff..];

        return Sections.Custom{
            .name = name,
            .bytes = bytes,
        };
    }

    pub fn parseCustomSection(self: *WasmModule) WasmError!?Sections.Custom {
        return self.parseSection(Sections.Custom, 0, customSectionParser);
    }

    fn functionSectionParser(module: WasmModule) WasmError!Sections.Function {
        const m = try module.nextVector(u32);

        return Sections.Function{
            .functypes = m,
        };
    }

    pub fn parseFunctionSection(self: *WasmModule) WasmError!?Sections.Function {
        return self.parseSection(Sections.Function, 3, functionSectionParser);
    }
};

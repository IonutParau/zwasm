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
    ref: RefType,
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

pub const CodeDef = struct {
    code: []const u8,
    locals: std.ArrayList(Locals),
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
        definitions: std.ArrayList(CodeDef),
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

    pub fn nextExpression(self: *WasmModule) WasmError![]const u8 {
        var i = self.i;
        var binary = self.binary;
        var j = self.i;

        while (try self.next(u8) != 0x0B) {
            j += 1;
        }

        return binary[i..j];
    }

    pub fn nextValType(self: *WasmModule) WasmError!ValueType {
        const byte = try self.next(u8);
        switch (byte) {
            0x7F => ValueType{ .num = NumType{.int32} },
            0x7E => ValueType{ .num = NumType{.int64} },
            0x7D => ValueType{ .num = NumType{.float32} },
            0x7C => ValueType{ .num = NumType{.float64} },
            0x7B => ValueType{.vec},
            0x70 => ValueType{ .ref = RefType{.funcref} },
            0x6F => ValueType{ .ref = RefType{.externref} },
            else => return WasmError.InvalidByte,
        }
    }

    pub fn nextResultType(self: *WasmModule) WasmError!ResultType {
        var len = try self.next(u32);
        var array = ResultType.init(self.allocator);
        errdefer array.deinit();

        while (len > 0) : (len -= 1) {
            try array.append(try self.nextValType());
        }

        return array;
    }

    pub fn nextFunctionType(self: *WasmModule) WasmError!FunctionType {
        if (try self.next(u32) != 0x60) {
            return WasmError.InvalidByte;
        }

        const inputs = try self.nextResultType();
        const outputs = try self.nextResultType();

        return FunctionType{
            .inputs = inputs,
            .outputs = outputs,
        };
    }

    // size + buffer where ||buffer|| = size
    fn nextBuffer(self: *WasmModule) WasmError![]const u8 {
        const len = try self.next(u32);
        const buffer = self.binary[self.i .. self.i + len];
        self.i += len;
        return buffer;
    }

    fn codeSectionParser(self: WasmModule) WasmError!Sections.Code {
        var codelen = try self.next(u32);
        var definitions = std.ArrayList(CodeDef).init(self.allocator);
        errdefer definitions.deinit();

        while (codelen > 0) : (codelen -= 1) {
            const function_buffer = try self.nextBuffer();
            var func = WasmModule.init(function_buffer, self.allocator); // this is to use convenience functions

            var localc = try func.next(u32);
            var locals = try std.ArrayList(Locals).initCapacity(self.allocator, @intCast(localc));
            errdefer locals.deinit();

            while (localc > 0) : (localc -= 1) {
                const count = try func.next(u32);
                const t = try func.nextValType();

                const local = Locals{
                    .count = count,
                    .t = t,
                };

                try locals.append(local);
            }

            var expression = try func.nextExpression();

            if (!func.done()) {
                return WasmError.WrongSize;
            }

            const def = CodeDef{
                .code = expression,
                .locals = locals,
            };

            try definitions.append(def);
        }

        return Sections.Code{
            .definitions = definitions,
        };
    }

    pub fn done(self: *WasmModule) bool {
        return self.i == self.binary.len;
    }

    pub fn parseCodeSection(self: *WasmModule) WasmError!?Sections.Custom {
        return self.parseSection(Sections.Custom, 10, codeSectionParser);
    }

    fn typeSectionParser(self: WasmModule) WasmError!Sections.Type {
        var types = std.ArrayList(FunctionType).init(self.allocator);
        errdefer types.deinit();
        var len = try self.next(u32);

        while (len > 0) : (len -= 1) {
            try types.append(try self.nextFunctionType());
        }

        return Sections.Type{
            .types = types,
        };
    }

    pub fn parseTypeSection(self: *WasmModule) WasmError!?Sections.Type {
        return self.parseSection(Sections.Type, 1, typeSectionParser);
    }
};

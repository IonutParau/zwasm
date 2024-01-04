# ZWasm

A library and utility for all things WebAssembly, written in Zig.

# Status

Under heavy development.

# What features it has now
None, good things take time.

# What features it will have
- Compile .wat files to .wasm
- Decompile .wasm into .wat
- Apply some level of optimizations
- Run .wasm files (with a library, so it could be used to embed WebAssembly)
- Optional support for WASI and WASIX out of the box
- Built-in support for 64-bit memory
- Support for stack-switching out of the box

# What features it may have later on
- asynchronous, non-blocking JIT compilation (likely with LLVM)
- support for WasmGC

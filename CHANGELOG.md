# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- docgen documents structs, type aliases, and modules, with documented struct fields rendered under the struct entry

  both markdown (revo docs) and html (revo docs --html) output formats are available
  this makes

    ```revo
    #* this is a struct *#
    struct S {
      #* holds a number *#
      x: num,
    }

    #* 2 digits of precision *#
    const pi = 3.14
    ```

- stdlib:
  - `exit(number)`
  - `revo.dofile(path)`

    like `revo.eval` but reads the source from a file, relative paths resolve against the current module's directory like `import`, then cwd
- zig extensions, examples for zig extensions (`examples/zig`)
- `HACKING.md`
- attribute syntax in the parser: `@[name]` lexes as an attribute and attaches to any declaration. will be used for applying procedural macros later

### Changed

- **Breaking:** doc-comments are `#* ... *#` now, comments attach to any declaration and are stored in types, hover follows aliases, repl `:h` renders exactly what hover renders
- **Breaking:** cli is now subcommand-based: `compile`, `repl`, `dis`, `bench`, `docs`, `lsp`. options must come before the script name, everything after goes to runtime argv. the old flags like `-b` and `--dis` are gone in favor of their subcommands
- **Breaking:** c api values use nanbox: `RevoData` is a single u64 now, boxed payloads are intern ids instead of pointers
- **Breaking:** stdlib `read()` renamed to `input()`, and only reads stdin lines. use `fs.open()?:read()` to read files
- `Native` renamed to `Host` throughout the codebase
- lsp: fn return type hints, nested document symbols, parameter hover and param types in hover signatures
- semantic: top-level re-declarations shadow the module surface while fn-local bindings no longer leak into it; table methods written as `fn name(self)` inside a table literal get typed

### Fixed

- compiler: table literal entries declaring bindings reserved parent-frame registers mid-expression, clobbering the table under construction and desyncing enclosing call windows ("want table, got function"). declaring entries now compile in an isolated child frame, and keyless binding entries land in the array part instead of under the binding's name
- `orelse` falls through on `:undef`, so `t.missing orelse 0` works for absent table keys (GH-40)
- diagnostics expand tabs to tab stops before rendering carets, which no longer drift left on tab-indented lines (GH-36)
- stdlib `len()` signature corrected from `number|:nil` to `number`
- lsp signature help deep-copies parsed types so shared comptime sentinels can't dangle

## [0.1.1] - 2026-08-10

### Added

- string interpolation with `#{x}` syntax
- slicing: `"asdf"[2..]`, `{1, 2, 3, 4}[..3]`, `"hello"[4..-1..1]`
- freestanding wasm support, see the `wasm` directory for integrations
- new arithmetic operations: `//`, `^`, `xor`, and the rest of the binary operations
- lsp: hover, semantic tokens, completion for imports, symbol rename
- feature flags in zig build: `mimalloc`, `regex`
- stdlib module `re` for regex
- stdlib module `rng`
- stdlib module `compress`

### Changed

- reworked iterators
- mimalloc is generally better than the standard allocator
- general perf is ~1.5x faster via better codegen and micro-optimisations

## [0.1.0a] - 2026-07-24

### Added

- wasm builds, see `wasm/` dir
- result/error type syntaxes: `!T/U :== (:ok, T) | (:err, U)` and `!T :== (:ok, T) | (:err, any)`
- docgen for the std through `zig build docs`
- new std module: `compress`
- compiler return type propagation

[Unreleased]: https://github.com/if-not-nil/revo/compare/0.1.1...HEAD
[0.1.1]: https://github.com/if-not-nil/revo/compare/0.1.0a...0.1.1
[0.1.0a]: https://github.com/if-not-nil/revo/releases/tag/0.1.0a

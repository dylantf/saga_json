# saga_json

A JSON library for [Saga](https://saga-lang.org). Parse, render,
encode, decode, transform. Hand-written or derived.

```saga
import SagaJson as J
import SagaJson.Codec (ToJson, FromJson, serialize, deserialize)

record User {
  name: String,
  age: Int,
} deriving (ToJson, FromJson)

main () = {
  serialize (User { name: "Alice", age: 30 })
  # "{"name":"Alice","age":30}"

  let input = """{"name":"Alice","age":30}"""
  deserialize input : Result User J.Error
  # Ok(User { name: "Alice", age: 30 })
}
```

## What you get

- Three layers. Drop in at whichever fits:
  - `Json` value AST (`SagaJson.Encode`/`SagaJson.Decode`) plus
    `render` and `parse_string` for hand-rolled work.
  - `ToJson` and `FromJson` traits (`SagaJson.Codec`) for per-type
    impls.
  - `serialize` and `deserialize` one-shot helpers on top.
- Deriving. `deriving (ToJson, FromJson)` on records and ADTs. No
  per-field boilerplate.
- Customization without writing the impl. `Options` controls key
  renaming (`CamelCase`, `SnakeCase`, etc.), ADT tag format
  (externally, adjacently, or internally tagged; untagged), and
  null-field omission.
- Escape hatches. `as_enum` and `as_tagged` strategy functions when
  the defaults are wrong. `update_field`, `rename_field`, and
  `map_object` for reshaping `Json` on the value path.
- Tuples (arity 2 through 10), `List`, `Maybe`, and the primitive
  types out of the box.
- Effect-typed errors. Decoders are `Json -> a needs {Fail Error}`,
  so failures compose like any other effectful code.

## Install

Add to your `project.toml`:

```toml
[dependencies]
saga_json = { git = "https://github.com/dylantf/saga_json" }
```

## Documentation

- [docs/guide/getting-started.md](docs/guide/getting-started.md).
  Install, first encode, first decode.
- [docs/guide/encoding.md](docs/guide/encoding.md). Hand-written
  impls, `deriving (ToJson)`, `serialize`.
- [docs/guide/decoding.md](docs/guide/decoding.md). Hand-written
  decoders, `deriving (FromJson)`, `deserialize`, error handling.
- [docs/guide/customization.md](docs/guide/customization.md). The
  `Options` record, ADT tag formats, key renaming, the `as_enum` and
  `as_tagged` strategies.
- [docs/guide/post-processing.md](docs/guide/post-processing.md).
  Transforming `Json` after encoding or before decoding.
- [docs/reference/index.md](docs/reference/index.md). API reference,
  per-module, generated from doc comments by `saga docs`.

## Examples

| Path                                                       | What it shows                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------------- |
| [src/EncodeDeriveCustom.saga](src/EncodeDeriveCustom.saga) | Derived encoder plus the `JsonOptions` effect and the `as_enum`/`as_tagged` strategies |

The broadest coverage of every path — hand-written and derived,
encode and decode, all `Options` knobs — lives in the test suite under
[tests/](tests/). Run the demo with `saga run`; run the tests with
`saga test`.

## Status

Unversioned, pre-1.0. The public surface (the three layers above) is
stable in intent, but large breaking changes and redesigns are still
on the table.

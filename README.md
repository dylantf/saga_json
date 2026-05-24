# saga_json

A JSON library for [Saga](https://saga-lang.org). Parse, render,
encode, decode, transform. Hand-written or derived.

```saga
import SagaJson.Encode as E (ToJson, serialize)
import SagaJson.Decode as D (FromJson, deserialize)

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
  - `Json` AST plus `render` and `parse_string` for hand-rolled work.
  - `ToJson` and `FromJson` traits for per-type impls.
  - `serialize` and `deserialize` one-shot helpers on top.
- Deriving. `deriving (ToJson, FromJson)` on records and ADTs. No
  per-field boilerplate.
- Customization without writing the impl. `Options` controls key
  renaming (`CamelCase`, `SnakeCase`, etc.), ADT tag format
  (externally, adjacently, or internally tagged; untagged), and
  null-field omission.
- Escape hatches. `as_enum` and `as_tagged` strategy functions when
  the defaults are wrong. `derive_with` to start from the derived
  shape and post-process. `update_field`, `rename_field`, and
  `map_object` for reshaping `Json` after the fact.
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

`src/` contains six self-contained demos, each exercising one
encode/decode path:

| Path                                                       | What it shows                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------------- |
| [src/DecodeHand.saga](src/DecodeHand.saga)                 | Decoding by hand: `field`, `string`, `int`, `at`                       |
| [src/DecodeDerive.saga](src/DecodeDerive.saga)             | `deriving (FromJson)` plus `deserialize`                               |
| [src/DecodeDeriveCustom.saga](src/DecodeDeriveCustom.saga) | Derived decoder plus `Options` for renaming and tag format             |
| [src/EncodeHand.saga](src/EncodeHand.saga)                 | Hand-written `impl ToJson` using the primitive constructors            |
| [src/EncodeDerive.saga](src/EncodeDerive.saga)             | `deriving (ToJson)` plus `serialize`, including tuples                 |
| [src/EncodeDeriveCustom.saga](src/EncodeDeriveCustom.saga) | Derived encoder plus `Options` and the `as_enum`/`as_tagged` strategies |

Run all demos with `saga run`. Run tests with `saga test`.

## Status

Unversioned, pre-1.0. The public surface (the three layers above) is
stable in intent, but large breaking changes and redesigns are still
on the table.

# saga_json

A JSON library for [Saga](https://saga-lang.org). The supported path is
explicit and composable: hand-write `ToJson` / `FromJson` impls using the
`SagaJson.Encode` builders and `SagaJson.Decode` combinators.

```saga
import Std.Fail (Fail)
import SagaJson as J
import SagaJson.Encode as E
import SagaJson.Encode (ToJson)
import SagaJson.Decode as D
import SagaJson.Decode (FromJson)

record User {
  name: String,
  age: Int,
} deriving (Debug)

impl ToJson for User {
  to_json u = E.object [("name", to_json u.name), ("age", to_json u.age)]
}

impl FromJson for User needs {Fail J.Error} {
  from_json j = User {
    name: D.at "name" D.string j,
    age: D.at "age" D.int j,
  }
}

main () = {
  let json = E.serialize (User { name: "Alice", age: 30 })
  # "{"name":"Alice","age":30}"

  D.deserialize json : Result User J.Error
  # Ok(User { name: "Alice", age: 30 })
}
```

## What You Get

- `Json`, an opaque JSON value type.
- `SagaJson.Encode` builders: `string`, `int`, `float`, `bool`, `null`,
  `array`, `object`, `list_of`, `nullable`, and `render`.
- `SagaJson.Encode.ToJson` with primitive, `List`, and `Maybe` impls, plus
  `encode` and `serialize`.
- `SagaJson.Decode` combinators: primitive decoders, `field`, `at`,
  `list_of`, `nullable`, and `refine`.
- `SagaJson.Decode.FromJson` with primitive, `List`, and `Maybe` impls, plus
  `decode` and `deserialize`.
- Object transform helpers such as `update_field`, `rename_field`,
  `remove_field`, `set_field`, `insert_field`, and `map_object`.

Removed surfaces stay removed: no deriving, no runtime `Options`, no
`SagaJson.Codec`, no `SagaJson.Mono`, no `Symbol`-reflected field names.

## Install

Add to your `project.toml`:

```toml
[dependencies]
saga_json = { git = "https://github.com/dylantf/saga_json" }
```

## Documentation

- [Getting started](docs/guide/getting-started.md)
- [Encoding](docs/guide/encoding.md)
- [Decoding](docs/guide/decoding.md)
- [Post-processing](docs/guide/post-processing.md)
- [API reference](docs/reference/index.md)

Run the demo with `saga run`; run the tests with `saga test`.

## Status

Unversioned, pre-1.0. The current surface is intentionally small while the
language settles after the removal of generic deriving, user-defined deriving,
and `Symbol`.

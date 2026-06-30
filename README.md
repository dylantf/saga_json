# saga_json

A JSON library for [Saga](https://saga-lang.org). The supported path is
explicit and composable: write encoder functions that produce `Json`, write
decoder functions from `SagaJson.Decode` combinators, and use `render` /
`parse` at the boundary.

```saga
import Std.Fail (Fail)
import SagaJson as J
import SagaJson.Encode as E
import SagaJson.Decode as D

record User {
  name: String,
  age: Int,
} deriving (Debug)

fun encode_user : User -> J.Json
encode_user u = E.object [("name", E.string u.name), ("age", E.int u.age)]

fun decode_user : J.Json -> User needs {Fail J.Error}
decode_user j = User {
  name: D.at "name" D.string j,
  age: D.at "age" D.int j,
}

main () = {
  let json = E.render (encode_user (User { name: "Alice", age: 30 }))
  # "{"name":"Alice","age":30}"

  J.parse decode_user json
  # Ok(User { name: "Alice", age: 30 })
}
```

## What You Get

- `Json`, an opaque JSON value type.
- `SagaJson.Encode` builders: `string`, `int`, `float`, `bool`, `null`,
  `array`, `object`, `list_of`, `nullable`, and `render`.
- `SagaJson.Decode` combinators: primitive decoders, `field`, `at`,
  `list_of`, `nullable`, and `refine`.
- Object transform helpers such as `update_field`, `rename_field`,
  `remove_field`, `set_field`, `insert_field`, and `map_object`.
- Effect-typed errors. Decoders are `Json -> a needs {Fail Error}`, and
  `SagaJson.run` / `SagaJson.parse` turn those failures into `Result`.

The old trait/derive codec APIs have been removed. There is no `ToJson`,
`FromJson`, `serialize`, `deserialize`, `Options`, `SagaJson.Codec`, or
`SagaJson.Mono` surface.

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
language settles after the removal of generic traits, user-defined deriving,
and `Symbol`.

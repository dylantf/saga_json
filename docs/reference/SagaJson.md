---
title: SagaJson
---

JSON library top-level: the `Json` opaque type, the shared `Error` type,
and the decoder-running entry points.

For encoding, see `SagaJson.Encode`. For decoding primitives and
combinators, see `SagaJson.Decode`.

## Types

### Json

```saga
opaque type Json
```

A JSON value. Opaque so the internal representation can evolve.
Construct with `SagaJson.Encode` primitives; inspect with
`SagaJson.Decode` combinators.

### Error

```saga
type Error =
  | InvalidJson String
  | InvalidShape (expected: String) (found: String) (path: List String)
  deriving (Eq, Debug)
```

Error returned when JSON parsing or decoding fails.

## Functions

### from_value

```saga
fun from_value : Value -> Json
```

Wrap a `Value` as a `Json`. Library-internal; use `SagaJson.Encode`.

### to_value

```saga
fun to_value : Json -> Value
```

Unwrap a `Json` to its underlying `Value`. Library-internal; use
`SagaJson.Decode` for ordinary decoding.

### parse_string

```saga
fun parse_string : String -> Result Json Error
```

Parse a JSON string into a `Json` value, without applying a decoder.

### run

```saga
fun run : (Json -> a needs {Fail Error, ..e}) -> Json -> Result a Error
  needs {..e}
```

Apply a decoder to an already-parsed `Json` value, returning a `Result`.

### parse

```saga
fun parse : (Json -> a needs {Fail Error, ..e}) -> String -> Result a Error
  needs {..e}
```

Parse a JSON string and apply a decoder in one step.

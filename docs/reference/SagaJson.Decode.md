---
title: SagaJson.Decode
---

JSON decoders, `FromJson`, and decoding helpers.

A decoder is a function `Json -> a needs {Fail Error}`. For typed values,
implement `FromJson` by composing the primitive decoders and combinators.

## Types

### FromJson

```saga
trait FromJson a {
  fun from_json : Json -> a needs {Fail Error}
}
```

Types that can be decoded from JSON. The library provides impls for `String`,
`Int`, `Float`, `Bool`, `List a`, and `Maybe a`.

## Functions

### string

```saga
fun string : Json -> String needs {Fail Error}
```

Decode a JSON string value.

### int

```saga
fun int : Json -> Int needs {Fail Error}
```

Decode a JSON integer value.

### float

```saga
fun float : Json -> Float needs {Fail Error}
```

Decode a JSON float value. Accepts integers as floats.

### bool

```saga
fun bool : Json -> Bool needs {Fail Error}
```

Decode a JSON boolean value.

### field

```saga
fun field : String -> Json -> Json needs {Fail Error}
```

Navigate to a named field in a JSON object.

### at

```saga
fun at : String -> (Json -> a needs {Fail Error, ..e}) -> Json -> a
  needs {Fail Error, ..e}
```

Navigate to a named field and apply `decoder` to it. Prefixes the field name
onto the path of any error raised inside `decoder`.

### list_of

```saga
fun list_of : (Json -> a needs {Fail Error, ..e}) -> Json -> List a
  needs {Fail Error, ..e}
```

Decode a JSON array, applying `decoder` to each element.

### nullable

```saga
fun nullable : (Json -> a needs {Fail Error, ..e}) -> Json -> Maybe a
  needs {Fail Error, ..e}
```

Decode a JSON value that may be null.

### decode

```saga
fun decode : Json -> Result a Error where {a: FromJson}
```

Decode an already-parsed `Json` value via its `FromJson` impl.

### deserialize

```saga
fun deserialize : String -> Result a Error where {a: FromJson}
```

Parse a JSON string and decode it via `FromJson`.

### refine

```saga
fun refine : (a -> a needs {Fail Error}) -> (Json -> a needs {Fail Error, ..e}) -> Json -> a
  needs {Fail Error, ..e}
```

Post-process a decoded value with an invariant check.

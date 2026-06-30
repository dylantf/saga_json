---
title: SagaJson.Encode
---

JSON builders, `ToJson`, rendering, and object transforms.

Construct `Json` values with primitive builders (`string`, `int`, `array`,
`object`, ...). For typed values, implement `ToJson`.

## Types

### ToJson

```saga
trait ToJson a {
  fun to_json : a -> Json
}
```

Types that can be encoded as JSON. The library provides impls for `String`,
`Int`, `Float`, `Bool`, `List a`, and `Maybe a`.

## Functions

### string

```saga
fun string : String -> Json
```

Encode a Saga `String` as a JSON string value.

### int

```saga
fun int : Int -> Json
```

Encode an `Int` as a JSON number.

### float

```saga
fun float : Float -> Json
```

Encode a `Float` as a JSON number.

### bool

```saga
fun bool : Bool -> Json
```

Encode a `Bool` as JSON `true` / `false`.

### null

```saga
fun null : Json
```

The JSON `null` value.

### array

```saga
fun array : List Json -> Json
```

Encode a list of `Json` values as a JSON array.

### list_of

```saga
fun list_of : (a -> Json) -> List a -> Json
```

Encode a list by applying an element encoder to each item.

### nullable

```saga
fun nullable : (a -> Json) -> Maybe a -> Json
```

Encode a `Maybe` as either JSON `null` or the encoded contained value.

### object

```saga
fun object : List (String, Json) -> Json
```

Encode a list of `(key, value)` pairs as a JSON object. Key order is
preserved.

### render

```saga
fun render : Json -> String
```

Render a `Json` value as a compact JSON string. Output round-trips through
`SagaJson.parse_string`.

### encode

```saga
fun encode : a -> Json where {a: ToJson}
```

Encode a value via its `ToJson` impl.

### serialize

```saga
fun serialize : a -> String where {a: ToJson}
```

Encode a value via `ToJson` and render it to a compact JSON string.

### update_field

```saga
fun update_field : String -> (Json -> Json needs {Fail Error, ..e}) -> Json -> Json
  needs {Fail Error, ..e}
```

Apply `f` to the value at `key`. Preserves key order. Fails if the key is
missing or the input is not an object.

### rename_field

```saga
fun rename_field : String -> String -> Json -> Json needs {Fail Error}
```

Rename `old` to `new`. Preserves position and value. Fails if `old` is
missing or the input is not an object.

### remove_field

```saga
fun remove_field : String -> Json -> Json needs {Fail Error}
```

Remove `key`. Fails if `key` is missing or the input is not an object.

### set_field

```saga
fun set_field : String -> Json -> Json -> Json needs {Fail Error}
```

Replace the value at `key` if it exists, otherwise append `(key, value)`.

### insert_field

```saga
fun insert_field : String -> Json -> Json -> Json needs {Fail Error}
```

Append `(key, value)`. Fails if `key` already exists or the input is not an
object.

### map_object

```saga
fun map_object : ((String, Json) -> (String, Json) needs {Fail Error, ..e}) -> Json -> Json
  needs {Fail Error, ..e}
```

Apply `f` to every `(key, value)` pair, replacing both. Preserves order.

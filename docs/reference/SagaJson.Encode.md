---
title: SagaJson.Encode
---

JSON encoders and rendering.

Construct `Json` values with the primitive functions (`string`, `int`,
`array`, `object`, ...). Use `render` to serialize a `Json` value to
a compact JSON string.

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

### object

```saga
fun object : List (String, Json) -> Json
```

Encode a list of (key, value) pairs as a JSON object. Key order is
preserved.

### render

```saga
fun render : Json -> String
```

Render a `Json` value as a compact JSON string (no whitespace).
Output round-trips through `SagaJson.parse_string`.

### update_field

```saga
fun update_field : String -> Json -> Json needs {Fail Error, ..e} -> Json -> Json needs {Fail Error, ..e}
```

Apply `f` to the value at `key`. Preserves key order. Fails with
InvalidShape if the key is missing or the input is not an object.
The callback may itself raise effects (typically used to nest other
post-process combinators on the inner Json).

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

Upsert: replace the value at `key` if it exists (preserving position),
otherwise append `(key, value)`. The unconditional-write variant; use
`update_field` or `insert_field` if you want missing/existing to fail.

### insert_field

```saga
fun insert_field : String -> Json -> Json -> Json needs {Fail Error}
```

Append `(key, value)`. Fails if `key` already exists (use `update_field`
to overwrite, or `set_field` to upsert) or the input is not an object.

### map_object

```saga
fun map_object : (String, Json) -> (String, Json) needs {Fail Error, ..e} -> Json -> Json needs {Fail Error, ..e}
```

Apply `f` to every `(key, value)` pair, replacing both. Useful for
uniform key transformations (e.g. camelCasing every key of a
dynamic-keyed `Map String _`). Preserves order. The callback may
itself raise effects.


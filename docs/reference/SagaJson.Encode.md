---
title: SagaJson.Encode
---

JSON encoders and rendering.

Construct `Json` values with the primitive functions (`string`, `int`,
`array`, `object`, ...). Use `render` to serialize a `Json` value to
a compact JSON string.

## Types

### Encoder

```saga
record Encoder a {
  value: a,
  options: Options
}
```

A typed value paired with the Options that should drive its
encoding. Build with `encoder` or `encode_with`, refine with the
`WithOptions` setters, then collapse via `to_json` or `serialize`.

## Traits

### ToJson

```saga
trait ToJson a {
  fun to_json_with : Options -> a -> Json
  fun to_json : a -> Json
}
```

Types that can be encoded as JSON. Hand-write `to_json_with` for your
own records and ADTs (the `to_json` convenience is inherited from the
trait default), or write `deriving (ToJson)`.

## Values

### null

```saga
fun null : Json
```

The JSON `null` value.

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

### serialize

```saga
fun serialize : a -> String where {a: ToJson}
```

Encode a value to a compact JSON string using default options.
Equivalent to `render (to_json x)`.

### serialize_with

```saga
fun serialize_with : Options -> a -> String where {a: ToJson}
```

Encode a value to a compact JSON string using the given options.
Equivalent to `render (to_json_with opts x)`.

### derive_with

```saga
fun derive_with : Options -> a -> Json where {a: Generic r, r: ToJson}
```

Derive-then-tweak escape hatch. Calls the Generic-derived encoding
explicitly, so a hand-written `impl ToJson` can start from the derived
shape and post-process. Without this, the trait dispatch can't reach
the derived impl, since the hand-written impl shadows it.

### as_enum

```saga
fun as_enum : Options -> a -> Json where {a: ToJson}
```

Encoding strategy: emit every variant as a bare JSON string of its
tag name (e.g. `"Admin"`), dropping any payload data. Lossy by
design — `Elevated 123` encodes to `"Elevated"`, discarding `123`.
Useful when a downstream system only cares about the tag (logging,
analytics, JSON shape compatibility with a foreign enum).

The symmetric decoder `SagaJson.Decode.as_enum_from` round-trips
unit variants but fails on payload-bearing ones — there's no payload
data in `"Elevated"` to reconstruct from.

### as_tagged

```saga
fun as_tagged : Options -> a -> Json where {a: ToJson}
```

Encoding strategy: force the externally-tagged `{"Variant": payload}`
shape for unit variants too. Recovers the pre-default-refinement
behavior of `{"Admin": null}`. Drives the encode through
`unit_variants_as_strings: False` regardless of the caller's Options.

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

### encoder

```saga
fun encoder : a -> Encoder a where {a: ToJson}
```

Wrap a value with `default_options`. The head of a fluent encode
chain: `value |> encoder |> rename_keys CamelCase |> serialize`.

### encode_with

```saga
fun encode_with : a -> Options -> Encoder a where {a: ToJson}
```

Wrap a value with a pre-built Options record. The shortcut when
you already have an Options value you want to reuse.

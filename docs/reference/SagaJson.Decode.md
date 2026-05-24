---
title: SagaJson.Decode
---

JSON decoders.

A decoder is a function `Json -> a needs {Fail Error}`. Compose them by
ordinary function call; failures short-circuit through the Fail handler.
Use `SagaJson.parse` or `SagaJson.run` to discharge the effect.

## Types

### Decoder

```saga
record Decoder {
  input: String,
  options: Options
}
```

An input JSON string paired with the Options that should drive its
decoding. Build with `decoder` or `decode_with`, refine with the
`WithOptions` setters, then collapse via `decode`.

## Traits

### FromJson

```saga
trait FromJson a {
  fun from_json_with : Options -> Json -> a
  fun from_json : Json -> a
}
```

Types that can be decoded from JSON. Hand-write `from_json_with` for
your own records and ADTs, or write `deriving (FromJson)`.

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
fun at : String -> Json -> a needs {Fail Error, ..e} -> Json -> a needs {Fail Error, ..e}
```

Navigate to a named field and apply `decoder` to it. Prefixes the
field name onto the path of any error raised inside `decoder`.

### list_of

```saga
fun list_of : Json -> a needs {Fail Error, ..e} -> Json -> List a needs {Fail Error, ..e}
```

Decode a JSON array, applying `decoder` to each element.

### nullable

```saga
fun nullable : Json -> a needs {Fail Error, ..e} -> Json -> Maybe a needs {Fail Error, ..e}
```

Decode a JSON value that may be null. Returns Nothing for null,
Just (decoder value) otherwise.

### deserialize

```saga
fun deserialize : String -> Result a Error where {a: FromJson}
```

Parse a JSON string and decode it via the FromJson trait, with default
options.

### deserialize_with

```saga
fun deserialize_with : Options -> String -> Result a Error where {a: FromJson}
```

Parse a JSON string and decode it via the FromJson trait, with the
given options.

### derive_from_with

```saga
fun derive_from_with : Options -> Json -> a needs {Fail Error} where {a: Generic r, r: FromJson}
```

Decode-side derive-then-tweak escape hatch. Calls the Generic-derived
decoder explicitly, so a hand-written `impl FromJson` can pre-process
the input Json and route the result through the derived decoder.
Mirror of `SagaJson.Encode.derive_with`.

### as_enum_from

```saga
fun as_enum_from : Options -> Json -> a needs {Fail Error} where {a: FromJson}
```

Decoding strategy: accept a bare JSON string as a variant tag.
Routes through the externally-tagged path with
`unit_variants_as_strings: True`, so unit variants decode from
`"Admin"` cleanly. Payload-bearing variants fail — there's no
payload data in a bare string to reconstruct from. Mirror of
`SagaJson.Encode.as_enum`.

### as_tagged_from

```saga
fun as_tagged_from : Options -> Json -> a needs {Fail Error} where {a: FromJson}
```

Decoding strategy: force the externally-tagged `{"Variant": payload}`
shape for unit variants too. Mirror of `SagaJson.Encode.as_tagged` —
drives the decode through `unit_variants_as_strings: False`
regardless of the caller's Options. Useful for decoding pre-default-
refinement JSON that always wraps unit variants.

### refine

```saga
fun refine : a -> a needs {Fail Error} -> Json -> a needs {Fail Error} -> Json -> a needs {Fail Error}
```

Post-process a decoded value with an invariant check. The decoder
produces a candidate value, then the invariant function may `fail!`
to reject values the schema can't express. Similar in spirit to a
zod refinement.

Example:
nonneg_age = refine (fun u -> if u.age >= 0 then u
else fail! (InvalidShape "age >= 0" "negative" []))
from_json

### decoder

```saga
fun decoder : String -> Decoder
```

Wrap an input string with `default_options`. The head of a fluent
decode chain: `input |> decoder |> rename_keys CamelCase |> decode`.

### decode_with

```saga
fun decode_with : String -> Options -> Decoder
```

Wrap an input string with a pre-built Options record. The shortcut
when you already have an Options value you want to reuse.

### decode

```saga
fun decode : Decoder -> Result a Error where {a: FromJson}
```

Collapse a `Decoder` builder: parse its input and run the derived
`FromJson` decoder using the builder's accumulated Options. The
target type is picked by the result-type annotation at the call site.


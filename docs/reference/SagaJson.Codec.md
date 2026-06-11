---
title: SagaJson.Codec
---

Fast JSON codec: encode straight to iodata, decode straight from bytes
into the target type — no intermediate `Json`/`Value` AST on either side.

This is the throughput path and the eventual `deriving` target. The
`Value`-based `SagaJson.Encode` / `SagaJson.Decode` remain the flexible
path (dynamic JSON, combinators, post-processing, internally-tagged /
untagged sums).

Options are passed explicitly as the first argument to `serialize_with` /
`deserialize_with` and threaded down through `to_json` / `from_json`;
`serialize` / `deserialize` use `default_options`.

## Types

### Iodata

```saga
type Iodata =
  | IoStr String
  | IoBytes BitString
  | IoMany (List Iodata)
```

A tree of binary fragments. Built compositionally, flattened once by
`to_string`. `IoStr` carries an ordinary String fragment; `IoBytes`
carries a raw slice (used by the escaper for zero-copy clean runs).

## Traits

### ToJson

```saga
trait ToJson a {
  fun to_json : Options -> a -> Iodata
}
```

Types that encode to a JSON `Iodata` tree. `to_json` takes the active
`Options` (threaded from the entry point) and the value. Library impls
thread `opts` to their children; record/variant impls consult it for
`rename_all`, `omit_nothings`, and tag format.

### FromJson

```saga
trait FromJson a {
  fun from_json : Options -> BitString -> Result (a, BitString) Error
}
```

Types that decode directly from JSON bytes. `from_json` takes the active
`Options` and the remaining input, returning the decoded value and the
unconsumed tail. Library impls ignore `opts`; record/variant impls use
it for `rename_all` and tag format.

## Functions

### object

```saga
fun object : List (String, Iodata) -> Iodata
```

Assemble a JSON object from `(key, Iodata)` pairs, for hand-written
`ToJson` impls. Keys are escaped; values are already-rendered `Iodata`,
so produce them by recursing through `to_json opts field` — that both
threads the ambient `Options` and lets the fused fast path apply.
Key order is preserved.

impl ToJson for Point {
to_json opts p = object [
("x", to_json opts p.x),
("y", to_json opts p.y),
]
}

### array

```saga
fun array : List Iodata -> Iodata
```

Assemble a JSON array from a list of already-rendered `Iodata`
elements, for hand-written `ToJson` impls. Produce elements with
`to_json opts x` so options thread through and the fused path applies.

impl ToJson for Pair {
to_json opts p = array [to_json opts p.fst, to_json opts p.snd]
}

### serialize

```saga
fun serialize : a -> String where {a: ToJson}
```

Encode a value to a compact JSON string using the canonical defaults.

### serialize_with

```saga
fun serialize_with : Options -> a -> String where {a: ToJson}
```

Encode a value using an explicit `Options` value (its first argument),
threaded down through the derived encoders.

### derive

```saga
fun derive : Options -> a -> Iodata where {a: Generic r, r: ToJson}
```

Call the Generic-derived encoding explicitly, so a hand-written
`impl ToJson` can start from the derived shape and post-process. Without
this the trait dispatch can't reach the derived impl (the hand-written
impl shadows it).

### as_enum

```saga
fun as_enum : Options -> a -> Iodata where {a: ToJson}
```

Encoding strategy: emit every variant as a bare JSON string of its tag
name, dropping payload data. Lossy by design. Mirror of `as_enum_from`.

### as_tagged

```saga
fun as_tagged : Options -> a -> Iodata where {a: ToJson}
```

Encoding strategy: force the externally-tagged `{"Variant": payload}`
shape for unit variants too (overrides `unit_variants_as_strings`).

### to_string

```saga
fun to_string : Iodata -> String
```

Flatten an `Iodata` tree to a String in one pass.

### to_bytes

```saga
fun to_bytes : Iodata -> BitString
```

Flatten an `Iodata` tree to a raw `BitString` in one pass. Used by the
Value bridge to re-parse a rendered payload without a String detour.

### render_value

```saga
fun render_value : Value -> Iodata
```

Render a concrete `Value` to fused `Iodata`. Keys are emitted verbatim
(any `rename_all` was already applied when the `Value` was built), so no
`Options` are consulted. Reuses the same object/array/string assembly as
the fused encoders.

### parse_value

```saga
fun parse_value : BitString -> Result (Value, BitString) Error
```

Parse a single JSON value from bytes into a `Value`, returning the
unconsumed tail. The buffering counterpart to the fused streaming
decoders: used by custom impls and by tag formats that must inspect a
whole sub-value before deciding its shape.

### deserialize

```saga
fun deserialize : String -> Result a Error where {a: FromJson}
```

Parse and decode a JSON string into the target type using defaults.

### deserialize_with

```saga
fun deserialize_with : Options -> String -> Result a Error where {a: FromJson}
```

Parse and decode using an explicit `Options` value (its first argument).

### derive_from

```saga
fun derive_from : Options -> BitString -> Result (a, BitString) Error where {a: Generic r, r: FromJson}
```

Call the Generic-derived decoding explicitly (mirror of `derive`), so a
hand-written `impl FromJson` can post-process the derived result.

### as_enum_from

```saga
fun as_enum_from : Options -> BitString -> Result (a, BitString) Error where {a: FromJson}
```

Decoding strategy: accept a bare JSON string as a variant tag. Routes
through `unit_variants_as_strings: True`. Mirror of `as_enum`.

### as_tagged_from

```saga
fun as_tagged_from : Options -> BitString -> Result (a, BitString) Error where {a: FromJson}
```

Decoding strategy: require the externally-tagged shape for unit variants
(overrides `unit_variants_as_strings`). Mirror of `as_tagged`.

### skip_ws

```saga
fun skip_ws : BitString -> BitString
```

Skip leading JSON whitespace.

### expect

```saga
fun expect : Int -> BitString -> Result BitString Error
```

Consume a specific byte (after whitespace), returning the rest.

### parse_string

```saga
fun parse_string : BitString -> Result (String, BitString) Error
```

Parse a JSON string value; return (decoded, rest).

### parse_int

```saga
fun parse_int : BitString -> Result (Int, BitString) Error
```

Parse a JSON integer; return (value, rest).

### parse_float

```saga
fun parse_float : BitString -> Result (Float, BitString) Error
```

Parse a JSON number as a Float (accepts integers too).

### parse_bool

```saga
fun parse_bool : BitString -> Result (Bool, BitString) Error
```

Parse a JSON boolean; return (value, rest).


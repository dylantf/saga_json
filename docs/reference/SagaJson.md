---
title: SagaJson
---

JSON library top-level: the `Json` opaque type, the shared `Error` type,
the `Options` record with its `default_options` and setter functions, and
the decoder-running entry points.

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

### NameStyle

```saga
type NameStyle =
  | AsIs
  | CamelCase
  | KebabCase
  | SnakeCase
  | ScreamingSnakeCase
```

How record field names and variant names are transformed before
emission (encode) or matched against input (decode). Source
convention is snake_case Saga identifiers (the type-level Symbol
reflects the source name verbatim); `rename_all` is applied to that
source name symmetrically on both directions.

### TagFormat

```saga
type TagFormat =
  | ExternallyTagged
  | AdjacentlyTagged
  | InternallyTagged
  | Untagged
```

How sum-type variants are tagged in JSON.

- `ExternallyTagged` (default): `{"Variant": payload}` for variants
that carry a payload; unit variants emit as bare strings
(`"Admin"`) when `unit_variants_as_strings` is True (the default).
- `AdjacentlyTagged`: `{<tag_field>: "Variant", <content_field>: payload}` —
both fields always emitted, including for unit (U1) variants where
`content_field` carries `null`.
- `InternallyTagged`: tag merged into the payload object as `<tag_field>`.
Only well-defined when the payload renders to a JSON object (single
record-valued variants) or `null` (unit variants). For primitive /
array payloads the encoder falls back to `ExternallyTagged` — same
restriction as serde.
- `Untagged`: emit the payload directly; variant identity is lost.

### Options

```saga
record Options {
  rename_all: NameStyle,
  omit_nothings: Bool,
  tag_format: TagFormat,
  tag_field: String,
  content_field: String,
  unit_variants_as_strings: Bool
}
```

Uniform codec options. Shared between encode and decode so a single
`Options` value drives a symmetric round-trip. Construct with
record-update syntax: `{ default_options | rename_all: CamelCase }`,
or chain the setters: `default_options |> rename_keys CamelCase`.
Note: `omit_nothings` is encode-only (no-op on decode).

Note: options are passed explicitly as the first argument to
`serialize_with` / `deserialize_with` (see `SagaJson.Codec`); build a
value from `default_options` and the setter functions below.

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

### default_options

```saga
fun default_options : Options
```

The canonical defaults: no renaming, emit nulls for `Maybe Nothing`,
externally-tagged sums with unit variants emitted as bare strings
(matching serde and most other modern JSON libraries). Set
`unit_variants_as_strings: False` to recover the legacy
`{"Admin": null}` shape (or use the `as_tagged` strategy).

Build a custom `Options` by piping `default_options` through the
setters below, e.g.
`default_options |> rename_keys CamelCase |> omit_nothings`, then pass
the result to `serialize_with` / `deserialize_with`.

### rename_keys

```saga
fun rename_keys : NameStyle -> Options -> Options
```

Set the `rename_all` field.

### omit_nothings

```saga
fun omit_nothings : Options -> Options
```

Set `omit_nothings: True`. Encode-only; no-op on the decode side
(decoders treat a missing field as an error, not as `Nothing`).

### tag_format

```saga
fun tag_format : TagFormat -> Options -> Options
```

Set the `tag_format` field.

### tag_field

```saga
fun tag_field : String -> Options -> Options
```

Set the `tag_field` name (used by AdjacentlyTagged / InternallyTagged).

### content_field

```saga
fun content_field : String -> Options -> Options
```

Set the `content_field` name (used by AdjacentlyTagged).

### unit_variants_as_strings

```saga
fun unit_variants_as_strings : Bool -> Options -> Options
```

Set the `unit_variants_as_strings` field. Pass False to recover the
legacy `{"Admin": null}` wrapped shape; True is the default.

### apply_name_style

```saga
fun apply_name_style : NameStyle -> String -> String
```

Apply a NameStyle transform to a Saga source identifier (snake_case
by convention). Library-internal; called by both the encoder and the
decoder so a single Options value drives a symmetric round-trip.

### parse_string

```saga
fun parse_string : String -> Result Json Error
```

Parse a JSON string into a Json value, without applying a decoder.

### run

```saga
fun run : Json -> a needs {Fail Error, ..e} -> Json -> Result a Error needs {..e}
```

Apply a decoder to an already-parsed Json value, returning a Result.

### parse

```saga
fun parse : Json -> a needs {Fail Error, ..e} -> String -> Result a Error needs {..e}
```

Parse a JSON string and apply a decoder in one step.


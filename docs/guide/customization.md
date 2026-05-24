# Customization

`Options` is a record of knobs that change how derived encoders and
decoders behave, without making you write the impl by hand. The same
`Options` value drives both directions, so a round-trip works when
both sides see the same value.

## The shape

```saga
pub record Options {
  rename_all: NameStyle,
  omit_nothing: Bool,
  tag_format: TagFormat,
  tag_field: String,
  content_field: String,
  unit_variants_as_strings: Bool,
}
```

Build by record-updating `default_options`:

```saga
let opts = { default_options | rename_all: CamelCase }
```

Pass to the `_with` variants:

```saga
E.serialize_with opts value
D.deserialize_with opts input
```

## `rename_all`

Transforms Saga field names (snake_case by convention) before emitting
them as JSON keys, and symmetrically on decode before matching them
against input keys.

| Style                | `user_name` becomes |
| -------------------- | ------------------- |
| `AsIs` (default)     | `user_name`         |
| `SnakeCase`          | `user_name`         |
| `CamelCase`          | `userName`          |
| `KebabCase`          | `user-name`         |
| `ScreamingSnakeCase` | `USER_NAME`         |

```saga
record User {
  first_name: String,
  last_name: String,
} deriving (ToJson, FromJson)

let opts = { default_options | rename_all: CamelCase }

serialize_with opts (User { first_name: "Ada", last_name: "Lovelace" })
# "{"firstName":"Ada","lastName":"Lovelace"}"

deserialize_with opts """{"firstName":"Ada","lastName":"Lovelace"}"""
  : Result User J.Error
# Ok(User { first_name: "Ada", last_name: "Lovelace" })
```

## `tag_format`

How sum-type variants are tagged in JSON.

```saga
type Status =
  | Active
  | Pending
```

### `ExternallyTagged` (default)

```json
{"Active": null}    // wrapped form when unit_variants_as_strings: False
"Active"            // bare-string form when unit_variants_as_strings: True (default)
{"Pending": 42}     // payload-bearing
```

### `AdjacentlyTagged`

```json
{"tag": "Active", "content": null}
{"tag": "Pending", "content": 42}
```

The field names for the tag and content come from `opts.tag_field`
and `opts.content_field`. Both fields are always emitted, including
for unit variants.

```saga
let opts = { default_options |
  tag_format: AdjacentlyTagged,
  tag_field: "tag",
  content_field: "value",
}
serialize_with opts Active
# "{"tag":"Active","value":null}"
```

### `InternallyTagged`

The tag is merged into the payload object as a field:

```json
{"tag": "Active"}              // unit variant
{"tag": "Address", "street": "Main", "city": "Springfield"}  // record-valued payload
```

Only well-defined when the payload renders to a JSON object (single
record-valued variants) or `null` (unit variants). For primitive or
array payloads the encoder falls back to `ExternallyTagged`. Same
restriction as `serde`.

### `Untagged`

The payload is emitted directly, no tag at all:

```json
null
42
```

Decoding `Untagged` JSON typically requires hand-written logic
because variant identity is lost on the wire.

## `omit_nothing`

When `True`, `Maybe Nothing` fields are dropped from the output
object entirely (rather than emitting `"field": null`).

```saga
record Notification {
  message: String,
  details: Maybe String,
} deriving (ToJson)

let opts = { default_options | omit_nothing: True }
serialize_with opts (Notification { message: "hello", details: Nothing })
# "{"message":"hello"}"
```

Encode-only. The decoder has no equivalent: a missing field is
treated as an error, not as `Nothing`. So `omit_nothing: True` breaks
the round-trip through `deserialize_with` on the same options. Use it
when you're emitting JSON for a consumer that prefers absence over
null, not when you also need to read your own output back.

## `unit_variants_as_strings`

When `True` (the default), unit variants encode as bare JSON strings
under `ExternallyTagged`:

```saga
serialize Admin  # ""Admin""
```

When `False`, unit variants emit the legacy wrapped form:

```saga
let opts = { default_options | unit_variants_as_strings: False }
serialize_with opts Admin  # "{"Admin":null}"
```

The decoder always accepts both forms regardless of this flag, so
flipping it on the encode side won't break existing decoders.

## Strategy functions: `as_enum` and `as_tagged`

`Options` covers uniform knobs that apply to every variant. The
strategy functions handle the per-type overrides that show up when
the defaults are wrong for a specific ADT.

### `as_enum`: emit every variant as a bare string

Drops any payload data, emitting just the tag. Lossy by design.
Useful when a downstream system only cares about the discriminator
(analytics, logging, foreign enum compatibility).

```saga
import SagaJson.Encode as E (as_enum, render)

type Event =
  | Heartbeat
  | Login Int
  deriving (ToJson)

render (as_enum default_options Heartbeat)   # ""Heartbeat""
render (as_enum default_options (Login 42))  # ""Login""  — 42 discarded
```

To make `as_enum` the default for a specific type, write the impl by
hand:

```saga
impl ToJson for Event {
  to_json_with opts e = as_enum opts e
}
```

The mirror on the decode side is `as_enum_from`:

```saga
let dec = fun jj -> (as_enum_from default_options jj : Event)
J.parse dec "\"Heartbeat\""  # Ok(Heartbeat)
```

Decoding `as_enum_from` works for unit variants. Payload-bearing
variants fail because there's no payload data in a bare string.

### `as_tagged`: emit every variant as a wrapped object

Forces the externally-tagged `{"Variant": payload}` shape for unit
variants too. Recovers the pre-default-refinement behavior.
Round-trips losslessly via `as_tagged_from`.

```saga
import SagaJson.Encode as E (as_tagged, render)

render (as_tagged default_options Heartbeat)   # "{"Heartbeat":null}"
render (as_tagged default_options (Login 42))  # "{"Login":42}"
```

To use as a hand impl:

```saga
impl ToJson for Event {
  to_json_with opts e = as_tagged opts e
}
```

And on the decode side:

```saga
let dec = fun jj -> (as_tagged_from default_options jj : Event)
J.parse dec "{\"Heartbeat\":null}"  # Ok(Heartbeat)
```

## Fluent builder API

If you're going to set more than one `Options` field, the record-update
syntax gets noisy. The `Encoder` / `Decoder` builders give you a
pipeline-friendly alternative:

```saga
import SagaJson as J (rename_keys, omit_nothing)
import SagaJson.Encode as E (encoder, serialize)

record User {
  first_name: String,
  detail: Maybe String,
} deriving (ToJson)

User { first_name: "Ada", detail: Nothing }
|> encoder
|> rename_keys CamelCase
|> omit_nothing
|> serialize
# "{"firstName":"Ada"}"
```

The chain works because `Encoder a` itself has a `ToJson` impl that
substitutes its accumulated `Options` when `serialize` (or `to_json`)
collapses the builder. The setters all live in `SagaJson` and are
written against a shared `WithOptions` trait, so both `Encoder` and
`Decoder` use the same vocabulary.

### Encode-side entry points

- `encoder : a -> Encoder a where {a: ToJson}`. Wraps a value with
  `default_options`. The head of a fluent chain.
- `encode_with : a -> Options -> Encoder a`. Wraps with a prebuilt
  `Options` value. Use when you already have an `Options` you want
  to reuse.

### Decode-side entry points

- `decoder : String -> Decoder`. Wraps an input string with
  `default_options`.
- `decode_with : String -> Options -> Decoder`. Wraps with a prebuilt
  `Options`.
- `decode : Decoder -> Result a Error where {a: FromJson}`. Collapses
  the builder, parses the input, and runs the derived decoder.

```saga
import SagaJson.Decode as D (decoder, decode)

"""{"firstName":"Ada","lastName":"Lovelace"}"""
|> decoder
|> rename_keys CamelCase
|> decode : Result User J.Error
# Ok(User { first_name: "Ada", last_name: "Lovelace" })
```

### The setters

| Function                          | Sets                                              |
| --------------------------------- | ------------------------------------------------- |
| `rename_keys : NameStyle -> _`    | `rename_all`                                      |
| `omit_nothing : _`                | `omit_nothing: True` (no-arg; encode-only)        |
| `with_tag_format : TagFormat -> _`| `tag_format`                                      |
| `with_tag_field : String -> _`    | `tag_field`                                       |
| `with_content_field : String -> _`| `content_field`                                   |
| `with_unit_variants_as_strings : Bool -> _` | `unit_variants_as_strings`              |

Each setter returns the same builder type with one field of the
underlying `Options` adjusted. Chain freely; order doesn't matter
since each one writes a single field.

The fluent API is a convenience over `serialize_with` /
`deserialize_with`. Use whichever reads better at the call site.
There's no behavioral difference.

## Round-trip safety

A round-trip with `serialize_with opts` followed by `deserialize_with
opts` is lossless for every `Options` combination except:

- `omit_nothing: True`. Encode drops null-valued fields. Decode
  requires them to be present.

The strategy functions also have a known asymmetry: `as_enum` is
lossy (payload data is discarded), so `as_enum` then `as_enum_from`
only round-trips unit variants.

All other knobs are symmetric.

# Customization

`Options` is a record of knobs that change how derived encoders and
decoders behave, without making you write the impl by hand. The same
`Options` value drives both directions, so a round-trip works when
both sides see the same value.

## The shape

```saga
pub record Options {
  rename_all: NameStyle,
  omit_nothings: Bool,
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

…or pipe `default_options` through the setters:

```saga
import SagaJson as J (rename_keys, omit_nothings, CamelCase)

let opts = default_options |> rename_keys CamelCase |> omit_nothings
```

## Applying options

`serialize_with` and `deserialize_with` take the `Options` value as
their first argument:

```saga
import SagaJson as J (rename_keys, CamelCase, default_options)
import SagaJson.Codec (serialize_with, deserialize_with)

let camel = rename_keys CamelCase default_options
serialize_with camel (User { first_name: "Ada", last_name: "Lovelace" })
# "{"firstName":"Ada","lastName":"Lovelace"}"
```

Bind the `Options` once and reuse it across as many encode/decode calls
as you like. The plain `serialize` / `deserialize` are just the
shortcuts for `serialize_with default_options` /
`deserialize_with default_options`.

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

let camel = rename_keys CamelCase default_options

serialize_with camel (User { first_name: "Ada", last_name: "Lovelace" })
# "{"firstName":"Ada","lastName":"Lovelace"}"

(deserialize_with camel """{"firstName":"Ada","lastName":"Lovelace"}"""
  : Result User J.Error)
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
let adjacent =
  default_options
  |> tag_format AdjacentlyTagged
  |> tag_field "tag"
  |> content_field "value"
serialize_with adjacent Active
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

Decoding `Untagged` JSON tries each variant in order and takes the
first that fits, so overlapping shapes resolve to the earliest
declared variant.

## `omit_nothings`

When `True`, `Maybe Nothing` fields are dropped from the output
object entirely (rather than emitting `"field": null`).

```saga
record Notification {
  message: String,
  details: Maybe String,
} deriving (ToJson)

serialize_with (omit_nothings default_options)
  (Notification { message: "hello", details: Nothing })
# "{"message":"hello"}"
```

Encode-only. The decoder has no equivalent: a missing field is
treated as an error, not as `Nothing`. So `omit_nothings: True` breaks
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
serialize_with (unit_variants_as_strings False default_options) Admin
# "{"Admin":null}"
```

The decoder always accepts both forms regardless of this flag, so
flipping it on the encode side won't break existing decoders.

## Strategy functions: `as_enum` and `as_tagged`

`Options` covers uniform knobs that apply to every variant. The
strategy functions handle the per-type overrides that show up when
the defaults are wrong for a specific ADT. They take an explicit
`Options` argument and return `Iodata`; flatten with `C.to_string`.

### `as_enum`: emit every variant as a bare string

Drops any payload data, emitting just the tag. Lossy by design.
Useful when a downstream system only cares about the discriminator
(analytics, logging, foreign enum compatibility).

```saga
import SagaJson.Codec as C (as_enum)

type Event =
  | Heartbeat
  | Login Int
  deriving (ToJson)

C.to_string (as_enum default_options Heartbeat)   # ""Heartbeat""
C.to_string (as_enum default_options (Login 42))  # ""Login""  — 42 discarded
```

To make `as_enum` the default for a specific type, write the impl by
hand:

```saga
impl ToJson for Event {
  to_json opts e = as_enum opts e
}
```

The mirror on the decode side is `as_enum_from`. Like the other
streaming decoders it takes a `BitString` and returns the decoded
value paired with the unconsumed tail:

```saga
import Std.BitString as BS
import SagaJson.Codec as C (as_enum_from)

case C.as_enum_from default_options (BS.from_string "\"Heartbeat\"") {
  Ok (event, _rest) -> (event : Event)    # Heartbeat
  Err e -> ...
}
```

Decoding `as_enum_from` works for unit variants. Payload-bearing
variants fail because there's no payload data in a bare string.

### `as_tagged`: emit every variant as a wrapped object

Forces the externally-tagged `{"Variant": payload}` shape for unit
variants too. Recovers the pre-default-refinement behavior.
Round-trips losslessly via `as_tagged_from`.

```saga
import SagaJson.Codec as C (as_tagged)

C.to_string (as_tagged default_options Heartbeat)   # "{"Heartbeat":null}"
C.to_string (as_tagged default_options (Login 42))  # "{"Login":42}"
```

To use as a hand impl:

```saga
impl ToJson for Event {
  to_json opts e = as_tagged opts e
}
```

The decode-side mirror is `as_tagged_from`.

## Round-trip safety

A round-trip with `serialize_with` followed by `deserialize_with`
using the *same* `Options` value is lossless for every `Options`
combination except:

- `omit_nothings: True`. Encode drops null-valued fields. Decode
  requires them to be present.

The strategy functions also have a known asymmetry: `as_enum` is
lossy (payload data is discarded), so `as_enum` then `as_enum_from`
only round-trips unit variants.

All other knobs are symmetric.

# Encoding

How to turn Saga values into JSON. Three options, from least to most
control: derive it, write the impl, or build a `Json` value directly.

The canonical encoder lives in `SagaJson.Codec`: the `ToJson` trait,
`serialize`/`serialize_with`, and the `object`/`array` builders. The
`SagaJson.Encode` module is the separate, flexible *value* API — `Json`
constructors and transforms — covered under "Building a Json value"
below.

## The shortest path: deriving

For records and ADTs whose JSON shape matches the type definition,
`deriving (ToJson)` synthesizes the impl:

```saga
import SagaJson.Codec (ToJson, serialize)

record Person {
  name: String,
  age: Int,
} deriving (ToJson)

serialize (Person { name: "Alice", age: 30 })
# "{"name":"Alice","age":30}"
```

`serialize` is the one-shot helper: it encodes the value to compact
`Iodata` and flattens it to a `String`.

Nesting composes. Any record whose fields all have `ToJson` impls can
itself derive `ToJson`:

```saga
record Address {
  street: String,
  city: String,
} deriving (ToJson)

record User {
  name: String,
  address: Address,
} deriving (ToJson)
```

## Built-in impls

These types have `ToJson` impls in the library:

- `String`, `Int`, `Float`, `Bool`
- `List a` where `a: ToJson`
- `Maybe a` where `a: ToJson`. `Just x` encodes as the underlying
  value, `Nothing` as JSON `null`.
- Tuples of arity 2 through 10 where every element has `ToJson`.
  Encoded as positional JSON arrays.

## Hand-written impls

When the JSON shape doesn't match the type definition, write the impl
by hand. `to_json` takes the ambient `Options` and the value, and
returns `Iodata`. Assemble it with the `object` and `array` builders
rather than writing braces by hand:

```saga
import SagaJson.Codec as C (ToJson, object, array)

record Point {
  x: Int,
  y: Int,
}

impl ToJson for Point {
  to_json opts p = C.object [
    ("x", to_json opts p.x),
    ("y", to_json opts p.y),
  ]
}
```

- `object` takes `(String, Iodata)` pairs and preserves key order.
- `array` takes a list of `Iodata` elements.
- Produce each value by recursing through `to_json opts field`. That
  threads the ambient `Options` (so `rename_all`, tag formats, etc.
  reach nested values) and keeps the value on the fused fast path.

The `opts` argument is threaded, not consumed: pass it down to every
nested `to_json`. If your impl hard-codes a shape that should ignore
options, you can name the argument `_`, but then nested renaming won't
apply.

## Building a Json value directly

When the shape is dynamic — driven by runtime data rather than a fixed
type — build a `Json` value with the constructors in `SagaJson.Encode`
and render it. This path goes through the intermediate `Json` AST, so
it is also the one to use when you want to *transform* the result (see
the [post-processing guide](post-processing.md)).

| Function | Input                 | Output                 |
| -------- | --------------------- | ---------------------- |
| `string` | `String`              | JSON string            |
| `int`    | `Int`                 | JSON number            |
| `float`  | `Float`               | JSON number            |
| `bool`   | `Bool`                | JSON `true` or `false` |
| `null`   | (value, not a fn)     | JSON `null`            |
| `array`  | `List Json`           | JSON array             |
| `object` | `List (String, Json)` | JSON object            |

```saga
import SagaJson.Encode as E

let j = E.object [
  ("name", E.string "Alice"),
  ("tags", E.array [E.string "admin", E.string "owner"]),
  ("age", E.int 30),
]
E.render j
# "{"name":"Alice","tags":["admin","owner"],"age":30}"
```

Note the two `object`/`array`: `E.object` builds a `Json` value and is
rendered with `E.render`; `C.object` (above) builds `Iodata` directly
inside a `ToJson` impl. Pick the value path for dynamic data and
transforms, the `Codec` builders for hand-written trait impls.

## ADTs

Sum types derive the same way as records:

```saga
type Role =
  | Admin
  | Editor
  | Viewer
  deriving (ToJson)

serialize Admin     # ""Admin""
serialize Editor    # ""Editor""
```

The default encoding is per-variant:

- Unit variants (no payload): bare JSON string of the variant name.
- Payload-bearing variants: externally tagged, `{"Variant": payload}`.
- Multi-arg variants: payload is a JSON array of the arguments.

```saga
type Event =
  | Heartbeat
  | Login Int
  | Click Int Int
  deriving (ToJson)

serialize Heartbeat     # ""Heartbeat""
serialize (Login 42)    # "{"Login":42}"
serialize (Click 10 20) # "{"Click":[10,20]}"
```

If you want every variant uniformly tagged, or every variant as a
bare string, see [`as_enum` and `as_tagged`](customization.md) in the
customization guide.

## `serialize_with`: customize with an `Options` value

`serialize` uses `default_options`. To override, build an `Options`
value and pass it as the first argument to `serialize_with`:

```saga
import SagaJson as J (rename_keys, CamelCase, default_options)
import SagaJson.Codec (serialize_with)

let camel = rename_keys CamelCase default_options
serialize_with camel (User { first_name: "Ada", last_name: "Lovelace" })
# "{"firstName":"Ada","lastName":"Lovelace"}"
```

Bind the `Options` once and reuse it across many serializations. Build
multi-knob policies by piping `default_options` through the setters:

```saga
let api_shape = default_options |> rename_keys CamelCase |> omit_nothings
serialize_with api_shape user
serialize_with api_shape notification
```

See the [customization guide](customization.md) for the full set of
`Options` fields and tag formats.

## Choosing a layer

- Use `deriving` when the JSON shape matches the type.
- Use a hand impl (with `C.object`/`C.array`) when the shape is fixed
  but different from the type, or when you want to compute fields.
- Use the `SagaJson.Encode` `Json` constructors when the shape is
  dynamic (driven by runtime data) or you need to transform the
  result before rendering.

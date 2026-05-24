# Encoding

How to turn Saga values into JSON. Three options, from least to most
control: derive it, write the impl, or build the `Json` AST directly.

## The shortest path: deriving

For records and ADTs whose JSON shape matches the type definition,
`deriving (ToJson)` synthesizes the impl:

```saga
import SagaJson.Encode as E (ToJson, serialize)

record Person {
  name: String,
  age: Int,
} deriving (ToJson)

serialize (Person { name: "Alice", age: 30 })
# "{"name":"Alice","age":30}"
```

`serialize` is the one-shot helper: it calls `to_json` on the value
and renders the result to a compact string. If you want the
intermediate `Json` value, call `E.to_json` directly and render
later.

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
by hand. You only need to implement `to_json_with`; the trait's
default body for `to_json` calls it with `default_options`.

```saga
record Person {
  name: String,
  age: Int,
}

impl ToJson for Person {
  to_json_with _ p = E.object [
    ("name", to_json p.name),
    ("age", to_json p.age),
  ]
}
```

`E.object` takes a list of `(String, Json)` pairs and preserves key
order. The `_` ignores the `Options` argument because this impl
hard-codes the shape. If you want `Options` to drive renaming or
similar, pass it through and call `to_json_with opts p.name` instead
of `to_json p.name`.

## Primitive constructors

When deriving doesn't fit and you want raw control, build `Json`
values directly:

| Function | Input              | Output                   |
| -------- | ------------------ | ------------------------ |
| `string` | `String`           | JSON string              |
| `int`    | `Int`              | JSON number              |
| `float`  | `Float`            | JSON number              |
| `bool`   | `Bool`             | JSON `true` or `false`   |
| `null`   | (value, not a fn)  | JSON `null`              |
| `array`  | `List Json`        | JSON array               |
| `object` | `List (String, Json)` | JSON object           |

Then `render` to serialize:

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

## `derive_with`: extend the derived shape

When you want most of the derived encoding but with one tweak, write
a hand impl that calls back into the derived encoder via
`derive_with`, then post-processes the `Json`:

```saga
record User {
  id: Int,
  name: String,
} deriving (ToJson)

impl ToJson for User {
  to_json_with opts u =
    derive_with opts u
    |> E.rename_field "id" "userId"
}
```

Without `derive_with`, the hand impl shadows the derived one, so the
trait dispatch can't reach it. `derive_with` is the explicit handle
back to the derived shape.

See the [post-processing guide](post-processing.md) for the full set
of `Json` transformers.

## `serialize_with`: pass `Options` at the call site

`serialize` uses `default_options`. To override, use `serialize_with`:

```saga
let opts = { default_options | rename_all: CamelCase }
serialize_with opts (User { first_name: "Ada", last_name: "Lovelace" })
# "{"firstName":"Ada","lastName":"Lovelace"}"
```

For multi-option setups, the fluent builder reads more naturally:

```saga
User { first_name: "Ada", last_name: "Lovelace" }
|> encoder
|> rename_keys CamelCase
|> serialize
```

See the [customization guide](customization.md) for both APIs and the
full set of `Options` fields.

## Choosing a layer

- Use `deriving` when the JSON shape matches the type.
- Use a hand impl when the shape is fixed but different from the
  type, or when you want to compute fields.
- Use `derive_with` when you want the derived shape with one or two
  edits.
- Use the `Json` primitives when the shape is dynamic (driven by
  runtime data) or you need full control.

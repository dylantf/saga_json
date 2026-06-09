# Decoding

How to turn JSON strings into Saga values. Same three options as
encoding: derive it, write a decoder with the combinators, or navigate
the `Json` AST by hand.

The canonical decoder lives in `SagaJson.Codec`: the `FromJson` trait
and `deserialize`/`deserialize_with`. The combinators
(`field`/`at`/`string`/`int`/`refine`/…) live in `SagaJson.Decode` —
the flexible value-based decoding API.

## The shortest path: deriving

For types whose JSON shape matches the definition, `deriving
(FromJson)` synthesizes the decoder:

```saga
import SagaJson as J
import SagaJson.Codec (FromJson, deserialize)

record Person {
  name: String,
  age: Int,
} deriving (FromJson)

deserialize """{"name":"Alice","age":30}""" : Result Person J.Error
# Ok(Person { name: "Alice", age: 30 })
```

The type annotation on `deserialize` is required. The function
returns `Result a Error`, and Saga uses the annotation to pick the
right `FromJson` impl.

Composition works the same as on the encode side: a record whose
fields all have `FromJson` impls can derive `FromJson`.

## Built-in impls

The same set of types as encoding:

- `String`, `Int`, `Float`, `Bool`
- `List a` where `a: FromJson`
- `Maybe a` where `a: FromJson`. JSON `null` decodes as `Nothing`,
  anything else as `Just x`.
- Tuples of arity 2 through 10 where every element has `FromJson`.
  Decoded from positional JSON arrays. Wrong-length arrays fail.

## Hand-written decoders

When the input shape doesn't match your type, decode with the
navigation combinators in `SagaJson.Decode`. A decoder is a function
`Json -> a needs {Fail Error}`; run it via `J.parse`:

```saga
import Std.Fail (Fail)
import SagaJson as J (Json)
import SagaJson.Decode as D

record Person {
  name: String,
  age: Int,
  email: Maybe String,
} deriving (Debug)

fun person_decoder : Json -> Person needs {Fail J.Error}
person_decoder j = Person {
  name: D.at "name" D.string j,
  age: D.at "age" D.int j,
  email: D.at "email" (D.nullable D.string) j,
}

J.parse person_decoder """{"name":"Alice","age":30,"email":null}"""
# Ok(Person { name: "Alice", age: 30, email: Nothing })
```

`D.at "name" decoder j` looks up `name` on the object and runs the
decoder on the value. `J.parse decoder input` parses the string into
`Json` and runs the decoder, returning `Result a Error`.

This is the path to use when an upstream service emits keys you'd
rather not name your fields after — just name the field in the
combinator (`D.at "userId" D.int j`) and store it wherever you like.
If the difference is a systematic casing convention, prefer the
`rename_all` option (see `deserialize_with` below) instead of a hand
decoder.

## Navigation and primitive decoders

The core decoders that show up in nearly every hand-written decoder:

| Function   | Decodes                                                       |
| ---------- | ------------------------------------------------------------- |
| `string`   | A JSON string into `String`                                   |
| `int`      | A JSON number into `Int` (rejects floats)                     |
| `float`    | A JSON number into `Float`. Accepts integers as floats.       |
| `bool`     | JSON `true`/`false` into `Bool`                               |
| `field`    | Look up a named field; returns the raw `Json`                 |
| `at`       | Look up a field and apply a decoder. Prefixes the path on failure. |
| `list_of`  | Decode a JSON array, applying a decoder to each element       |
| `nullable` | `Nothing` for JSON `null`, `Just (decoder v)` otherwise       |

## Errors

Failures land as `Err e` where `e: Error`:

```saga
type Error =
  | InvalidJson String
  | InvalidShape (expected: String) (found: String) (path: List String)
```

- `InvalidJson` for parse failures (malformed JSON).
- `InvalidShape` for decode failures (wrong type, missing field,
  bad variant tag). The `path` field tracks where in the input the
  failure happened.

`D.at` automatically prefixes its field name onto the path of any
error raised inside its decoder, so nested failures point at the
right place.

```saga
J.parse person_decoder """{"name":"Eve","age":"thirty"}"""
# Err(InvalidShape "Int" "String" ["age"])
```

## ADTs

Sum types derive the same way:

```saga
type Role =
  | Admin
  | Editor
  | Viewer
  deriving (FromJson)

deserialize "\"Admin\"" : Result Role J.Error      # Ok(Admin)
deserialize "{\"Admin\":null}" : Result Role J.Error  # Ok(Admin), legacy form
```

The decoder accepts both the bare-string form (the default encoding
for unit variants) and the legacy `{"Variant": null}` form for
backwards compatibility.

Payload-bearing variants decode from the externally-tagged form by
default:

```saga
type Event =
  | Heartbeat
  | Login Int
  | Click Int Int
  deriving (FromJson)

deserialize "{\"Login\":42}" : Result Event J.Error       # Ok(Login 42)
deserialize "{\"Click\":[10,20]}" : Result Event J.Error  # Ok(Click 10 20)
```

If your input uses a different tag shape, see
[customization](customization.md) for `AdjacentlyTagged`,
`InternallyTagged`, and `Untagged`.

## `deserialize_with`: customize via the `JsonOptions` effect

`deserialize` uses `default_options`. To override, install a
`JsonOptions` handler and use `deserialize_with`, which reads the
ambient options:

```saga
import SagaJson as J (json_opts, rename_keys, CamelCase)
import SagaJson.Codec (deserialize_with)

{
  (deserialize_with """{"firstName":"Ada","lastName":"Lovelace"}"""
    : Result User J.Error)
} with json_opts (rename_keys CamelCase)
```

The consumer's options must match whatever the producer used. See the
[customization guide](customization.md).

## `refine`: post-decode validation

For invariants the type system can't express (positive numbers,
non-empty strings, dates in range), wrap a decoder with `refine`:

```saga
fun nonneg_age : User -> User needs {Fail J.Error}
nonneg_age u =
  if u.age >= 0 then u
  else fail! (J.InvalidShape "age >= 0" "negative" ["age"])

let strict_user = D.refine nonneg_age person_decoder
J.parse strict_user """{"name":"x","age":-1}"""
# Err(InvalidShape "age >= 0" "negative" ["age"])
```

`refine` runs after the decoder produces a candidate value and either
returns it unchanged or raises. It takes any decoder
(`Json -> a needs {Fail Error}`), so pair it with a combinator
decoder like `person_decoder` above. Same effect type as the rest of
decoding, so failures compose normally.

## Choosing a layer

- Use `deriving` when the JSON shape matches the type.
- Use a combinator decoder (`D.at`/`D.string`/`D.field`/…) when the
  input shape is fixed but different, or you want to mix in
  validation.
- Use `deserialize_with` under a `JsonOptions` handler when the only
  difference is a systematic option like `rename_all` or a tag format.
- Drop to `D.string` / `D.int` / `D.field` directly when the input
  shape is dynamic or you want fine-grained error messages.

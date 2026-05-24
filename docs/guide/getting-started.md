# Getting started

A short walk through encoding a record to JSON and decoding it back.

## Install

Add `saga_json` to your `project.toml`:

```toml
[dependencies]
saga_json = { git = "https://github.com/dylantf/saga_json" }
```

Then `saga install` to fetch it.

## Three layers

`saga_json` has three layers. Use whichever fits the task:

1. The `Json` AST. Build values with `string`, `int`, `array`,
   `object`. Serialize with `render`. Parse with `parse_string`. Use
   this when the JSON shape doesn't map cleanly to a Saga type.
2. The `ToJson` and `FromJson` traits. Write an impl by hand or use
   `deriving`. Composition is automatic: a record whose fields all
   have impls gets one too.
3. The `serialize` and `deserialize` one-shot helpers on top of the
   traits. Typed value to JSON string and back, in a single call.

Most code lives at layer 2 or 3.

## Encode

The shortest encoder is `deriving (ToJson)` plus `serialize`:

```saga
import SagaJson.Encode as E (ToJson, serialize)

record Person {
  name: String,
  age: Int,
} deriving (ToJson)

main () = {
  serialize (Person { name: "Alice", age: 30 })
  # "{"name":"Alice","age":30}"
}
```

`deriving (ToJson)` synthesizes the impl. `serialize` calls `to_json`
on the value and renders the result to a compact string.

Lists, `Maybe`, tuples (arity 2 through 10), and the primitive types
(`String`, `Int`, `Float`, `Bool`) all have impls out of the box.

## Decode

The mirror image. Add `FromJson` to the `deriving` clause and call
`deserialize`:

```saga
import SagaJson as J
import SagaJson.Decode as D (FromJson, deserialize)

record Person {
  name: String,
  age: Int,
} deriving (FromJson)

main () = {
  let input = """{"name":"Alice","age":30}"""
  deserialize input : Result Person J.Error
  # Ok(Person { name: "Alice", age: 30 })
}
```

`deserialize` returns `Result a Error`. On success, `Ok value`. On
failure (missing field, wrong shape, parse error), `Err e`. The error
carries a description plus the path to where it went wrong.

The type annotation matters. `deserialize` returns a generic
`Result a Error`, so Saga needs the annotation to know what `a` is.

## Round-trip

Combine the two and anything you encode comes back equal to what you
put in (modulo `Float` precision):

```saga
record Person {
  name: String,
  age: Int,
} deriving (Debug, Eq, ToJson, FromJson)

main () = {
  let alice = Person { name: "Alice", age: 30 }
  let json = serialize alice
  let back = deserialize json : Result Person J.Error
  back == Ok alice  # True
}
```

If you pass `Options` on one side, pass the same `Options` on the
other or the round-trip breaks. See the [customization
guide](customization.md) for the cases where it does and doesn't
work.

## ADTs

Sum types derive the same way:

```saga
type Role =
  | Admin
  | Editor
  | Viewer
  deriving (ToJson, FromJson)
```

Unit variants encode as bare JSON strings (`"Admin"`).
Payload-bearing variants encode as externally-tagged objects
(`{"Mention": "alice"}`). This matches the `serde` default. The
decoder also accepts the legacy wrapped form (`{"Admin": null}`) for
backwards compatibility.

If you want every variant as a bare string regardless of payload, or
every variant wrapped regardless of arity, see the `as_enum` and
`as_tagged` strategies in the [customization
guide](customization.md).

## What's next

- [Encoding guide](encoding.md). Hand-written impls, the primitive
  constructors, and `derive_with`.
- [Decoding guide](decoding.md). Decoder combinators, error shapes,
  navigating nested JSON by hand.
- [Customization guide](customization.md). `Options`, ADT tag
  formats, key renaming, strategy functions.
- [Post-processing guide](post-processing.md). `update_field`,
  `rename_field`, `map_object` for reshaping `Json` after the fact.

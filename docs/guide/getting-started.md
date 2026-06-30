# Getting Started

The library has one supported path: define the JSON shape explicitly.

- Encode with functions that return `Json`, using `SagaJson.Encode`.
- Decode with functions `Json -> a needs {Fail Error}`, using
  `SagaJson.Decode`.
- Use `E.render` to turn `Json` into a compact string.
- Use `J.parse decoder input` to parse and decode in one step.

```saga
import Std.Fail (Fail)
import SagaJson as J
import SagaJson.Encode as E
import SagaJson.Decode as D

record Person {
  name: String,
  age: Int,
  email: Maybe String,
} deriving (Debug)

fun encode_person : Person -> J.Json
encode_person p =
  E.object [
    ("name", E.string p.name),
    ("age", E.int p.age),
    ("email", E.nullable E.string p.email),
  ]

fun decode_person : J.Json -> Person needs {Fail J.Error}
decode_person j = Person {
  name: D.at "name" D.string j,
  age: D.at "age" D.int j,
  email: D.at "email" (D.nullable D.string) j,
}

main () = {
  let alice = Person { name: "Alice", age: 30, email: Just "a@example.com" }
  let json = E.render (encode_person alice)
  let back = J.parse decode_person json
  dbg back
}
```

Missing fields and wrong shapes become `InvalidShape` errors. Invalid JSON
syntax becomes `InvalidJson`.

The removed codec path is intentionally not documented here: no generic
`ToJson` / `FromJson` traits, no deriving, no runtime `Options` record.

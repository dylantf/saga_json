# Getting Started

Define the JSON shape explicitly with hand-written traits.

- Encode by implementing `SagaJson.Encode.ToJson`.
- Decode by implementing `SagaJson.Decode.FromJson`.
- Compose impls from `SagaJson.Encode` builders and `SagaJson.Decode`
  combinators.
- Use `E.serialize` and `D.deserialize` at string boundaries.

```saga
import Std.Fail (Fail)
import SagaJson as J
import SagaJson.Encode as E
import SagaJson.Encode (ToJson)
import SagaJson.Decode as D
import SagaJson.Decode (FromJson)

record Person {
  name: String,
  age: Int,
  email: Maybe String,
} deriving (Debug)

impl ToJson for Person {
  to_json p =
    E.object [
      ("name", to_json p.name),
      ("age", to_json p.age),
      ("email", to_json p.email),
    ]
}

impl FromJson for Person needs {Fail J.Error} {
  from_json j = Person {
    name: D.at "name" D.string j,
    age: D.at "age" D.int j,
    email: D.at "email" from_json j,
  }
}

main () = {
  let alice = Person { name: "Alice", age: 30, email: Just "a@example.com" }
  let json = E.serialize alice
  let back = D.deserialize json : Result Person J.Error
  dbg back
}
```

Missing fields and wrong shapes become `InvalidShape` errors. Invalid JSON
syntax becomes `InvalidJson`.

The removed paths are intentionally absent: no deriving, no runtime `Options`,
no `SagaJson.Codec`, and no `Symbol`-based reflected field names.

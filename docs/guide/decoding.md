# Decoding

For typed values, implement `FromJson`.

```saga
import Std.Fail (Fail)
import SagaJson as J
import SagaJson.Decode as D
import SagaJson.Decode (FromJson)

record Point {
  x: Int,
  y: Int,
} deriving (Debug)

impl FromJson for Point needs {Fail J.Error} {
  from_json j = Point {
    x: D.at "x" D.int j,
    y: D.at "y" D.int j,
  }
}

D.deserialize """{"x":1,"y":2}""" : Result Point J.Error
```

Primitive decoders:

- `D.string`
- `D.int`
- `D.float`
- `D.bool`

Navigation and composition:

```saga
D.field "name" j
D.at "name" D.string j
D.list_of from_json j
D.nullable D.string j
```

The `FromJson` trait already has impls for primitives, `List a`, and
`Maybe a`, so nested fields can often use `from_json` directly.

```saga
record Drawing {
  name: String,
  points: List Point,
  note: Maybe String,
} deriving (Debug)

impl FromJson for Drawing needs {Fail J.Error} {
  from_json j = Drawing {
    name: D.at "name" D.string j,
    points: D.at "points" from_json j,
    note: D.at "note" from_json j,
  }
}
```

`D.at` prefixes errors with the field path. For example, decoding
`{"address":{"zip":123}}` with `D.at "address" (D.at "zip" D.string)`
returns a path like `["address", "zip"]`.

Use `D.refine` for validation that JSON shape alone cannot express.

```saga
fun nonnegative : Point -> Point needs {Fail J.Error}
nonnegative p =
  if p.x >= 0 && p.y >= 0 then p
  else fail! (J.InvalidShape "nonnegative point" "negative coordinate" [])

fun decode_nonnegative_point : J.Json -> Point needs {Fail J.Error}
decode_nonnegative_point = D.refine nonnegative from_json
```

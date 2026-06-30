# Decoding

A decoder is a function:

```saga
Json -> a needs {Fail Error}
```

Run a decoder with `SagaJson.run`, or parse and decode a string with
`SagaJson.parse`.

```saga
import Std.Fail (Fail)
import SagaJson as J
import SagaJson.Decode as D

record Point {
  x: Int,
  y: Int,
} deriving (Debug)

fun decode_point : J.Json -> Point needs {Fail J.Error}
decode_point j = Point {
  x: D.at "x" D.int j,
  y: D.at "y" D.int j,
}

J.parse decode_point """{"x":1,"y":2}"""
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
D.list_of decode_point j
D.nullable D.string j
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
decode_nonnegative_point = D.refine nonnegative decode_point
```

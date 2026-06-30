# Encoding

An encoder is a normal Saga function that returns `Json`.

```saga
import SagaJson as J
import SagaJson.Encode as E

record Point {
  x: Int,
  y: Int,
}

fun encode_point : Point -> J.Json
encode_point p = E.object [("x", E.int p.x), ("y", E.int p.y)]
```

Primitive builders:

- `E.string : String -> Json`
- `E.int : Int -> Json`
- `E.float : Float -> Json`
- `E.bool : Bool -> Json`
- `E.null : Json`

Container builders:

```saga
E.array [E.int 1, E.int 2]
E.list_of E.string ["admin", "editor"]
E.nullable E.int (Just 42)
E.object [("name", E.string "Alice"), ("age", E.int 30)]
```

Nested data composes by calling the child encoder.

```saga
record User {
  name: String,
  points: List Point,
}

fun encode_user : User -> J.Json
encode_user u =
  E.object [
    ("name", E.string u.name),
    ("points", E.list_of encode_point u.points),
  ]
```

Render with `E.render`:

```saga
E.render (encode_point (Point { x: 1, y: 2 }))
# "{"x":1,"y":2}"
```

For custom shapes, just write the shape. A sum type can encode as a string,
an externally tagged object, or whatever your API needs.

```saga
type Role =
  | Admin
  | Editor

fun encode_role : Role -> J.Json
encode_role r = case r {
  Admin -> E.string "admin"
  Editor -> E.string "editor"
}
```

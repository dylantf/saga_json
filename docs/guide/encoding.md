# Encoding

For typed values, implement `ToJson`.

```saga
import SagaJson.Encode as E
import SagaJson.Encode (ToJson)

record Point {
  x: Int,
  y: Int,
}

impl ToJson for Point {
  to_json p = E.object [("x", to_json p.x), ("y", to_json p.y)]
}
```

Primitive builders:

- `E.string : String -> Json`
- `E.int : Int -> Json`
- `E.float : Float -> Json`
- `E.bool : Bool -> Json`
- `E.null : Json`

Container helpers:

```saga
E.array [E.int 1, E.int 2]
E.list_of E.string ["admin", "editor"]
E.nullable E.int (Just 42)
E.object [("name", E.string "Alice"), ("age", E.int 30)]
```

The `ToJson` trait already has impls for primitives, `List a`, and `Maybe a`,
so nested data usually composes by calling `to_json`.

```saga
record User {
  name: String,
  points: List Point,
}

impl ToJson for User {
  to_json u =
    E.object [
      ("name", to_json u.name),
      ("points", to_json u.points),
    ]
}
```

Use `E.encode` when you want the intermediate `Json`, or `E.serialize` when
you want a compact string.

```saga
E.serialize (Point { x: 1, y: 2 })
# "{"x":1,"y":2}"
```

For custom shapes, just write the shape. A sum type can encode as a string,
an externally tagged object, or whatever your API needs.

```saga
type Role =
  | Admin
  | Editor

impl ToJson for Role {
  to_json r = case r {
    Admin -> E.string "admin"
    Editor -> E.string "editor"
  }
}
```

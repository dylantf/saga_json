---
title: SagaJson.Decode
---

JSON decoders.

A decoder is a function `Json -> a needs {Fail Error}`. Compose them by
ordinary function call; failures short-circuit through the Fail handler.
Use `SagaJson.parse` or `SagaJson.run` to discharge the effect.

## Functions

### string

```saga
fun string : Json -> String needs {Fail Error}
```

Decode a JSON string value.

### int

```saga
fun int : Json -> Int needs {Fail Error}
```

Decode a JSON integer value.

### float

```saga
fun float : Json -> Float needs {Fail Error}
```

Decode a JSON float value. Accepts integers as floats.

### bool

```saga
fun bool : Json -> Bool needs {Fail Error}
```

Decode a JSON boolean value.

### field

```saga
fun field : String -> Json -> Json needs {Fail Error}
```

Navigate to a named field in a JSON object.

### at

```saga
fun at : String -> Json -> a needs {Fail Error, ..e} -> Json -> a needs {Fail Error, ..e}
```

Navigate to a named field and apply `decoder` to it. Prefixes the
field name onto the path of any error raised inside `decoder`.

### list_of

```saga
fun list_of : Json -> a needs {Fail Error, ..e} -> Json -> List a needs {Fail Error, ..e}
```

Decode a JSON array, applying `decoder` to each element.

### nullable

```saga
fun nullable : Json -> a needs {Fail Error, ..e} -> Json -> Maybe a needs {Fail Error, ..e}
```

Decode a JSON value that may be null. Returns Nothing for null,
Just (decoder value) otherwise.

### refine

```saga
fun refine : a -> a needs {Fail Error} -> Json -> a needs {Fail Error, ..e} -> Json -> a needs {Fail Error, ..e}
```

Post-process a decoded value with an invariant check. The decoder
produces a candidate value, then the invariant function may `fail!`
to reject values the schema can't express. Similar in spirit to a
zod refinement.

Example:
person = fun j -> Person { name: field "name" string j, age: field "age" int j }
nonneg_age = refine (fun u -> if u.age >= 0 then u
else fail! (InvalidShape "age >= 0" "negative" []))
person


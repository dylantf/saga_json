# Post-processing

A set of combinators that transform a `Json` value after it's been
built and before it's rendered (or after it's parsed and before it's
decoded). Useful for reshaping output to match a foreign API, or
reshaping input to match what `deriving (FromJson)` expects.

All combinators operate on JSON objects only. Non-object input fails
with `InvalidShape`. They all live in `SagaJson.Encode`, but they're
direction-neutral: you can call them on the encode side before
`render` or on the decode side before passing to a derived decoder.

## The combinators

| Function       | Behavior                                                       |
| -------------- | -------------------------------------------------------------- |
| `update_field` | Apply a function to the value at `key`. Fails if missing.      |
| `rename_field` | Rename `old` to `new`. Fails if `old` is missing.              |
| `remove_field` | Delete `key`. Fails if `key` is missing.                       |
| `set_field`    | Replace if present, append if missing. Unconditional write.    |
| `insert_field` | Append `(key, value)`. Fails if `key` already exists.          |
| `map_object`   | Apply a function to every `(key, value)` pair.                 |

Strict-by-default: `update_field`, `rename_field`, `remove_field`,
and `insert_field` all fail loudly on the obvious mistake (missing
key, duplicate key). `set_field` is the unconditional-write escape
hatch when you don't want the failure.

## Composition

The intended usage is `|>`-chained pipelines:

```saga
import SagaJson.Encode as E

let reshape : Json -> Json needs {Fail Error}
reshape j =
  j
  |> E.remove_field "internal_id"
  |> E.rename_field "user_id" "id"
  |> E.insert_field "version" (E.int 2)
```

Order matters: each step sees the output of the previous one. If you
rename then try to remove the old name, you get a missing-key
failure.

## On the encode side

`derive_with` gives you the derived `Json`, then you transform it
before `render` picks it up:

```saga
record User {
  user_id: Int,
  name: String,
} deriving (ToJson)

impl ToJson for User {
  to_json_with opts u =
    derive_with opts u
    |> E.rename_field "user_id" "id"
    |> E.insert_field "version" (E.int 2)
}

serialize (User { user_id: 1, name: "Alice" })
# "{"name":"Alice","id":1,"version":2}"
```

## On the decode side

`derive_from_with` accepts a `Json` and runs the derived decoder. You
can reshape the input first:

```saga
record User {
  user_id: Int,
  name: String,
} deriving (FromJson)

impl FromJson for User {
  from_json_with opts j =
    j
    |> E.rename_field "id" "user_id"  # input uses "id", field is user_id
    |> derive_from_with opts
}

deserialize """{"id":1,"name":"Alice"}""" : Result User J.Error
# Ok(User { user_id: 1, name: "Alice" })
```

The transform combinators raise `Fail Error`, which composes
naturally with `from_json_with`'s effect signature.

## Nested updates

`update_field` takes a function `Json -> Json needs {Fail Error}`, so
you can nest it for deep updates:

```saga
# Input: {"user": {"name": "alice", "id": 1}}
# Output: {"user": {"name": "ALICE", "id": 1}}
j |> E.update_field "user" (fun inner ->
  inner |> E.update_field "name" (fun name_j ->
    E.string (String.to_upper (D.string name_j))))
```

The lambda receives the inner `Json` so you can chain more
combinators or build a replacement.

## `map_object`: bulk key/value rewrites

When every key needs the same treatment (renaming a dynamic-keyed
`Map String _`, lowercasing every key, etc.), `map_object` walks the
whole object:

```saga
j |> E.map_object (fun (k, v) -> (String.to_upper k, v))
# {"name":"Alice"} -> {"NAME":"Alice"}
```

Both the key and the value are replaceable. The callback runs with
the same effect type as the other combinators, so it can fail.

## When to reach for this vs. `Options`

- `Options` for uniform behavior across every field or variant
  (rename every key, change every tag format).
- Post-processing combinators for targeted, per-field reshaping
  (rename one key, add one computed field, drop one internal
  field).

The two combine cleanly: derive with `Options`, then post-process the
specific things `Options` can't reach.

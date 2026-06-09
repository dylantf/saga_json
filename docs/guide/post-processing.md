# Post-processing

A set of combinators that transform a `Json` value: reshape output to
match a foreign API, or reshape parsed input to match what a decoder
expects.

All combinators operate on JSON objects only. Non-object input fails
with `InvalidShape`. They all live in `SagaJson.Encode`, but they're
direction-neutral: call them on a `Json` you built before `render`, or
on a `Json` you parsed before running a decoder.

These transforms work on the `Json` *value* path — the
`SagaJson.Encode` constructors and `SagaJson.Decode` combinators — not
on the fused `Iodata` produced by a derived `ToJson`. For systematic
reshaping of derived output (renaming every key, changing tag format)
reach for [`Options`](customization.md) instead; use these combinators
for targeted, per-field edits on the value path.

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

Build the `Json` with the `Encode` constructors, transform it, then
`render`:

```saga
import SagaJson.Encode as E

let j = E.object [
  ("user_id", E.int 1),
  ("name", E.string "Alice"),
]
E.render (
  j
  |> E.rename_field "user_id" "id"
  |> E.insert_field "version" (E.int 2)
)
# "{"id":1,"name":"Alice","version":2}"
```

If you want to start from a *derived* shape and tweak it, serialize
the value, parse it back into a `Json`, transform, and re-render:

```saga
do {
  Ok j <- J.parse_string (serialize (User { user_id: 1, name: "Alice" }))
  Ok (E.render (j |> E.rename_field "user_id" "id"))
} else { Err e -> Err e }
```

## On the decode side

Parse the input to a `Json`, reshape it, then run a combinator
decoder over the result with `J.run`:

```saga
import SagaJson as J
import SagaJson.Decode as D

fun user_decoder : Json -> User needs {Fail J.Error}
user_decoder j = User {
  user_id: D.at "user_id" D.int j,
  name: D.at "name" D.string j,
}

do {
  Ok j <- J.parse_string """{"id":1,"name":"Alice"}"""
  J.run user_decoder (j |> E.rename_field "id" "user_id")  # input uses "id"
} else { Err e -> Err e }
# Ok(User { user_id: 1, name: "Alice" })
```

The transform combinators raise `Fail Error`, which composes
naturally with the decoder's effect signature.

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

The two combine cleanly: derive or build with `Options`, then
post-process the specific things `Options` can't reach.

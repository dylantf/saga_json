# Post-Processing

`SagaJson.Encode` includes single-level object transforms for cases where it
is simpler to build a broad shape first and then adjust it.

```saga
import SagaJson as J
import SagaJson.Encode as E

fun public_user : J.Json -> J.Json needs {Fail J.Error}
public_user j =
  j
  |> E.remove_field "password_hash"
  |> E.rename_field "manager" "supervisor"
  |> E.insert_field "schema_version" (E.int 2)
```

Available transforms:

- `update_field key f`
- `rename_field old new`
- `remove_field key`
- `set_field key value`
- `insert_field key value`
- `map_object f`

They operate on JSON objects only. Missing keys and duplicate-key inserts
fail loudly with `InvalidShape`, which helps catch stale field names after
schema changes.

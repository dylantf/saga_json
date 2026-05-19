# Serialization — Phased Implementation Plan

Companion to [../serialization.md](../serialization.md). That doc explains *what* and *why*; this doc is *how* and *when*. Agents picking up a phase should read both.

## Conventions for agents

- Read [../serialization.md](../serialization.md) before starting. Especially the "Why not attributes" and "Options" sections — there's design that's easy to violate without context.
- Add code to [lib/SagaJson.saga](../../../lib/SagaJson.saga) unless a phase says otherwise. Keep the module flat; resist creating new modules until the file is genuinely too large.
- Do **not** touch [lib/Parser.saga](../../../lib/Parser.saga). The parser is stable. Encoder work is downstream of the existing `Value` ADT.
- Do **not** introduce attribute machinery (`@json.rename`, etc.). The decision is documented; don't relitigate it in code.
- Don't add `Options` fields beyond the ones spec'd in the design doc, even if tempted. Especially nothing per-field.
- After each phase, update [src/Main.saga](../../../src/Main.saga) with an example exercising the new API. The `Main.saga` examples are the integration test surface.
- Verify each phase compiles and runs (`saga run` or whatever the project entrypoint is — check [project.toml](../../../project.toml)). Report any compiler bugs encountered separately; don't paper over them.

## Phase dependency graph

```
Phase 1 (encoder primitives + render)
   ↓
Phase 2 (ToJson trait + primitive/container impls)
   ↓
Phase 3 (post-process combinators)
   ↓
Phase 4 (Generic integration)  ← blocked on compiler
   ↓
Phase 5 (FromJson + shared infrastructure)
```

Phases 1–3 can ship before any compiler work lands. Phase 4 requires Generic auto-derive (`saga/examples/99-generic-spike.saga` → Phase 3 of the compiler spike). Phase 5 reuses Phase 4 infrastructure.

Within a phase, sub-tasks may be parallelizable; called out per phase.

---

## Phase 1: Encoder primitives + renderer

**Goal:** Construct `Json` values directly and serialize them to strings. No traits, no Generic. Validates round-tripping against the existing parser.

**Why first:** Smallest unit of useful work. Everything else builds on these primitives. Surfaces any latent issues with `Value` / `Json` before more code depends on them.

### Deliverables

In [lib/SagaJson.saga](../../../lib/SagaJson.saga):

```
pub fun string : String -> Json
pub fun int    : Int -> Json
pub fun float  : Float -> Json
pub fun bool   : Bool -> Json
pub val null   : Json
pub fun array  : List Json -> Json
pub fun object : List (String, Json) -> Json

pub fun render : Json -> String
```

Each constructor is a one-liner wrapping the corresponding `Value` case. `render` walks the `Value` tree and produces a compact (no whitespace) JSON string.

### `render` requirements

- Output is valid JSON parseable by `parse_string`.
- Strings: byte-level walk over the input (via `BS.from_string`), emit:
  - `\"` for `"`
  - `\\` for `\`
  - `\n` `\r` `\t` `\b` `\f` for those control chars (inverse of `escape_byte` in [lib/Parser.saga](../../../lib/Parser.saga))
  - `\u00XX` for other bytes `< 0x20`
  - All other bytes (including high-bit UTF-8 continuation bytes) pass through verbatim
- Numbers: use `show` (Int / Float Show instances). If float formatting produces something un-parseable (e.g. `"inf"`), fail loudly — don't silently emit invalid JSON. For now, document the assumption that finite floats are the only supported case.
- Arrays: `[` items separated by `,` `]`. Empty array: `[]`.
- Objects: `{` `"key":value` pairs separated by `,` `}`. Empty object: `{}`. Key strings get the same escaping as value strings.
- No spaces, no newlines.

### Tests / acceptance

Add to [src/Main.saga](../../../src/Main.saga) a section that:

1. Builds a `Json` value by hand using the new constructors, calls `render`, prints result.
2. Round-trip: `parse_string user_json` → `render` → parse the result again → verify equal to the first parse. Whitespace differences are expected; structural equality of `Json` values is what we check.
3. Edge cases worth exercising in `dbg` output: empty string `""`, string with embedded quotes `"a\"b"`, string with backslash `"a\\b"`, string with newline `"a\nb"`, empty array, empty object, nested object, array of mixed types if mixed types are even possible (they are, via `List Json`).

### Out of scope for this phase

- No `ToJson` trait. Users build `Json` values directly.
- No pretty-printing.
- No Unicode escape handling beyond control-char escapes (high-bit bytes pass through; the parser's `\u` handling is also incomplete and that's fine).

### Parallelizable subtasks

- (a) Constructor functions — trivial, 10 lines.
- (b) `render` for primitives + arrays + objects — main work.
- (c) String escape logic — isolated, can be unit-tested separately.

These can be done in any order but all in one PR; not worth splitting.

---

## Phase 2: `ToJson` trait + primitive/container impls

**Goal:** Introduce trait-based dispatch so callers can write `to_json x` and pass things around generically.

**Depends on:** Phase 1 (constructors must exist).

### Deliverables

In [lib/SagaJson.saga](../../../lib/SagaJson.saga):

```
pub trait ToJson a {
  fun to_json : a -> Json
}

impl ToJson for String { to_json s = string s }
impl ToJson for Int    { to_json n = int n }
impl ToJson for Float  { to_json f = float f }
impl ToJson for Bool   { to_json b = bool b }

impl ToJson for List a where {a: ToJson} {
  to_json xs = array (List.map to_json xs)
}

impl ToJson for Maybe a where {a: ToJson} {
  to_json m = case m {
    Nothing -> null
    Just x  -> to_json x
  }
}
```

Note: `to_json` has no effect row. Encoding cannot fail.

### Tests / acceptance

Update [src/Main.saga](../../../src/Main.saga):

1. Hand-write `impl ToJson for Coords`, `Address`, `User` (the existing record types). Each impl uses `object [...]` + per-field `to_json` calls or primitive constructors.
2. Call `to_json some_user |> render` and verify the output is valid JSON.
3. Round-trip: `parse parse_user (render (to_json original_user))` → verify the parsed result equals the original.
4. Verify the `List`/`Maybe` impls work via the existing `roles: List String` and `manager: Maybe String` fields.

### Decisions to lock in this phase (matches design doc)

- `Maybe Nothing` encodes to `null` (lossless, symmetric with decoding).
- No `Float` special cases — just `show`. Document any limitations encountered.

### Out of scope

- No Generic integration. Records still need hand-written impls.
- No post-process combinators yet.

### Parallelizable subtasks

- Trait declaration + primitive impls (one task).
- Container impls (`List`, `Maybe`) — depends on primitives.
- `Main.saga` hand-written impls — depends on both.

Sequential within a phase, but small enough that one agent does the whole phase.

---

## Phase 3: Post-process combinators

**Goal:** Let Tier 2 impls derive-then-tweak the resulting `Json` value. Useful even before Generic — works with hand-written impls too.

**Depends on:** Phase 1 (operates on `Json`).

### Deliverables

In [lib/SagaJson.saga](../../../lib/SagaJson.saga):

```
pub fun update_field : String -> (Json -> Json) -> Json -> Json needs {Fail Error}
pub fun rename_field : String -> String -> Json -> Json needs {Fail Error}
pub fun remove_field : String -> Json -> Json needs {Fail Error}
pub fun insert_field : String -> Json -> Json -> Json needs {Fail Error}
pub fun map_object   : ((String, Json) -> (String, Json)) -> Json -> Json needs {Fail Error}
```

Notes:

- All five operate on `VObject` only. If called on a non-object, fail with `InvalidShape "Object" <found> []`. Reuse the existing `Error` type.
- `update_field` and `rename_field` and `remove_field` fail loudly if the key is missing. Missing-key is almost always a bug (typo or stale post-process after a field rename) and we'd rather catch it than silently no-op. Document this.
- `insert_field` fails if the key already exists. (Use `update_field` to overwrite.) Forces explicitness about intent.
- `map_object` applies the transformer to every `(key, value)` pair. Useful for uniform key transformations on dynamic-key maps (e.g., serialized `Map String _` fields).
- Order preservation: `update_field` and `rename_field` preserve key order. `insert_field` appends. `map_object` preserves order.

### Tests / acceptance

Update [src/Main.saga](../../../src/Main.saga):

1. Take a `to_json user` result and pipe it through `rename_field "manager" "supervisor"`. Verify output.
2. Use `update_field "address" (fun addr -> addr |> remove_field "zip")` to demonstrate nested manipulation via composition.
3. Test failure paths: `rename_field "nonexistent" ...` should produce a `Fail Error`. Demonstrate the failure surfaces cleanly (e.g., via `with to_result`).
4. Use `map_object` on a `Json` value to uppercase all keys, as a smoke test of the uniform-keys use case.

### Design constraints (do not violate)

- Each combinator names **one key at one level**. No path strings (`"address.zip"`). Nesting is done by passing a lambda that operates on the inner `Json` — see the design doc's worked example.
- No combinator should accept a `List String` "path" argument. If you find yourself wanting one, stop and re-read the design doc.

### Parallelizable subtasks

Five independent functions; one agent can do all five in one pass. The shared concern is error handling — pick a consistent pattern (probably `needs {Fail Error}`) before writing the first one.

---

## Phase 4: Generic integration

**Goal:** `deriving (ToJson)` works for user records and ADTs. `generic_to_json` + `Options` unlock Tier 2's "derive-with-knobs" middle ground.

**Depends on:**

- Phases 1–3 complete.
- **Compiler:** Generic auto-derived for records and ADTs (`saga/examples/99-generic-spike.saga` Phase 3 equivalent).
- **Compiler:** `deriving (ToJson)` synthesizes the delegating impl `impl ToJson for T { to_json u = to_json (to u) }`.
- **Compiler (ideally):** Trait method default implementations, so `deriving (ToJson)` can emit `impl ToJson for T {}` with the default `to_json = generic_to_json default_options`. Without this, the synthesized impl spells out the call.

This phase cannot start until those are in place. Verify each compiler dependency before kicking off implementation.

### Deliverables

In [lib/SagaJson.saga](../../../lib/SagaJson.saga):

```
# Rep building-block impls (mirror the spike)
impl ToJson for U1      { to_json _ = null }
impl ToJson for Leaf a where {a: ToJson} { ... }
impl ToJson for Labeled a where {a: ToJson} { ... }       # may need ToJsonFields helper trait — see design doc
impl ToJson for And l r where {l: ToJsonFields, r: ToJsonFields} { ... }
impl ToJson for Or l r where {l: ToJson, r: ToJson} { ... }

# Helper trait for record interiors (And-trees of Labeled leaves)
pub trait ToJsonFields a {
  fun to_fields : a -> List (String, Json)
}
# + impls for Labeled and And

# Options + generic entry point
pub record Options {
  rename_all   : NameStyle,
  omit_nothing : Bool,
  tag_format   : TagFormat,
  tag_field    : String,
  content_field: String,
}

pub type NameStyle = AsIs | CamelCase | KebabCase | SnakeCase | ScreamingSnakeCase
pub type TagFormat = ExternallyTagged | AdjacentlyTagged | InternallyTagged | Untagged

pub val default_options : Options
pub fun generic_to_json : Options -> a -> Json where {a: Generic a r, ToJson r}
```

### Canonical default shape (locked here, hard to change later)

| Aspect | Default |
|---|---|
| Sum encoding | `ExternallyTagged` |
| Unit constructors | `{"Admin": null}` (do not specialize to bare strings in v1) |
| `Maybe Nothing` | `null` |
| Field naming | `AsIs` (use Saga field name unchanged) |

### Tests / acceptance

Update [src/Main.saga](../../../src/Main.saga):

1. Replace one of the existing hand-written `ToJson` impls (e.g., for `Coords`) with `deriving (ToJson)`. Verify output matches the hand-written version byte-for-byte.
2. Add a Tier 2 example: keep the hand-written impl on `User`, but body is `to_json u = generic_to_json (Options { rename_all: CamelCase, ..default_options }) u`. Verify camelCased output.
3. Add a Tier 2 example combining Generic with post-process combinators: `generic_to_json default u |> rename_field "manager" "supervisor"`.
4. Test an ADT with `deriving (ToJson)` — e.g., a `Role = Admin | Editor | Viewer` type — and verify the externally-tagged output.
5. Conflict rule: write a type with both `deriving (ToJson)` and a hand-written `impl ToJson for X` in the same module. Verify compile error pointing at both sites. (May require compiler support — if not yet implemented, file as a follow-up.)

### Out of scope

- No attribute system. (Yes, even for `@json.rename`. Don't.)
- No per-field overrides in `Options`. (Yes, even tempting "just one little `field_renames: Map`." Don't.)
- No `FromJson` yet — Phase 5.

### Parallelizable subtasks

- Rep building-block impls (`U1`, `Leaf`, `Labeled`, `And`, `Or`) — agent A
- `Options` types + `default_options` + `generic_to_json` — agent B
- `Main.saga` examples — depends on both, sequential
- Name-style helpers (`camel_case : String -> String` etc.) — agent C, independent

Three agents can work in parallel on A/B/C; example update sequential after.

---

## Phase 5: `FromJson` + shared infrastructure

**Goal:** Symmetric decode path. Reuse `Options` knobs (the same `rename_all`, `tag_format`, etc. apply in reverse). Add post-process `refine` for decoders to handle invariants the schema can't express.

**Depends on:** Phase 4 complete.

### Deliverables

```
pub trait FromJson a {
  fun from_json : Json -> a needs {Fail Error}
}

# Primitive + container impls mirroring ToJson

pub fun generic_from_json : Options -> Json -> a needs {Fail Error} where {a: Generic a r, FromJson r}

pub fun refine : (a -> a needs {Fail Error}) -> (Json -> a needs {Fail Error}) -> Json -> a needs {Fail Error}
```

`refine` wraps a decoder and applies an extra invariant check (zod-style). Distinct from the current `Fail Error` short-circuit in that it post-processes a successfully decoded value.

### Tests / acceptance

1. Round-trip every type touched in Phase 4: encode with `to_json`, decode with `from_json`, verify equality.
2. With non-default `Options`, verify symmetry: `from_json options (to_json options x) == x` for the matching options on both sides.
3. `refine` example: a `User` with `age >= 0` invariant. Verify the refined decoder fails on negative ages with a clear error.

### Open questions to resolve in this phase

- How does the existing `parse` / `run` API in [lib/SagaJson.saga](../../../lib/SagaJson.saga) compose with the new trait? Probably `from_json` should *be* a decoder (`Json -> a needs {Fail Error}`), so `parse from_json some_string` works. Verify before designing.
- Should `Options` be split into `EncodeOptions` and `DecodeOptions`, or stay unified? Unified is simpler; some options (e.g., `omit_nothing`) only make sense in one direction. Lean unified, document irrelevant fields per direction.

---

## Phase boundaries — what NOT to bundle

Each phase is a separable shippable unit. Don't:

- Mix Phase 1 work into Phase 2 because "it's just one more thing." The `ToJson` trait is genuinely separate from the renderer.
- Add Generic-related code in Phases 1–3 even speculatively. If Generic shifts shape during compiler work, speculative code becomes wrong-shaped code.
- Add `FromJson` work in Phase 4 — the decoder problem has its own design surface that benefits from being designed against finished encoder code, not in parallel with it.

## When to stop and ask

Bring questions back to the human before deciding:

- Any temptation to add attributes (`@json.*`) anywhere
- Any temptation to add per-field knobs to `Options`
- Any temptation to add path-string arguments to combinators (`update_field "a.b.c"`)
- Compiler bug or gap that blocks a phase — don't work around silently
- A canonical default shape decision that the design doc doesn't already pin down

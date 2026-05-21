# Serialization — Phased Implementation Plan

Companion to [../serialization.md](../serialization.md). That doc explains *what* and *why*; this doc is *how* and *when*. Agents picking up a phase should read both.

## Conventions for agents

- Read [../serialization.md](../serialization.md) before starting. Especially the "Why not attributes" and "Options" sections — there's design that's easy to violate without context.
- Module layout after Phase 0:
  - `lib/SagaJson.saga` — shared types (`Json` opaque type, `Error`), `parse_string` (neutral entry point)
  - `lib/SagaJson/Encode.saga` — encoder primitives, `render`, `ToJson` trait, building-block impls, `Options`, layer-3 `serialize`/`serialize_with`, `derive_with`
  - `lib/SagaJson/Decode.saga` — decoder primitives, combinators (`field`, `at`, `list_of`, `nullable`), `run`/`parse`, `FromJson` trait (Phase 5)
- Do **not** touch [lib/Parser.saga](../../../lib/Parser.saga). The parser is stable. Encoder work is downstream of the existing `Value` ADT.
- Do **not** introduce attribute machinery (`@json.rename`, etc.). The decision is documented; don't relitigate it in code.
- Don't add `Options` fields beyond the ones spec'd in the design doc, even if tempted. Especially nothing per-field.
- After each phase, update [src/Main.saga](../../../src/Main.saga) with an example exercising the new API. The `Main.saga` examples are the integration test surface.
- Verify each phase compiles and runs (`saga run` or whatever the project entrypoint is — check [project.toml](../../../project.toml)). Report any compiler bugs encountered separately; don't paper over them.

## Phase dependency graph

```
Phase 0 (module split: Encode / Decode)
   ↓
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

Phases 0–3 can ship before any compiler work lands. Phase 4 requires Generic auto-derive (`saga/examples/99-generic-spike.saga` → Phase 3 of the compiler spike). Phase 5 reuses Phase 4 infrastructure.

Within a phase, sub-tasks may be parallelizable; called out per phase.

---

## Phase 0: Module split

**Goal:** Restructure the existing single-module library into `SagaJson` (shared) + `SagaJson.Encode` + `SagaJson.Decode`. Prevents the imminent collision between encoder primitives (`string : String -> Json`) and existing decoder primitives (`string : Json -> String needs {Fail Error}`), and gives the library a clean dual-namespace structure that scales through Phase 5.

**Why a separate phase:** The collision blocks Phase 1, and the refactor is mechanical enough to dispatch independently. Doing it as a discrete step also keeps Phase 1's diff focused on new encoder code rather than reorganization.

### Deliverables

**File structure:**

```
lib/
  Parser.saga              # untouched
  SagaJson.saga            # shared types only
  SagaJson/
    Encode.saga            # NEW — empty stub for now (Phase 1 fills it)
    Decode.saga            # NEW — existing decoder code moves here
```

**`lib/SagaJson.saga` retains:**

- `Json` opaque type
- `Error` type
- `parse_string : String -> Result Json Error` (neutral — parses a String into a Json AST; not encode or decode in the typed sense)
- Re-export the `Json` and `Error` types so users can `import SagaJson (Json, Error)`

**`lib/SagaJson/Decode.saga` gets:**

- All current primitive decoders: `string`, `int`, `float`, `bool`
- Combinators: `field`, `at`, `list_of`, `nullable`
- Runners: `run`, `parse`
- The `to_result` handler
- Internal helpers: `unwrap`, `classify`, `shape_err`, `prefix_path` (or leave them in `SagaJson` if `Encode` will also need them — `classify` and `shape_err` are decoder-specific so probably move; `unwrap` is shared)

**`lib/SagaJson/Encode.saga` gets:**

- Empty stub. Phase 1 will fill it.

### Imports

Both `Encode` and `Decode` import from `SagaJson` (for `Json`, `Error`) and from `SagaJson.Parser` (for `Value`). Neither imports the other — no circular import risk.

### Migration of [src/Main.saga](../../../src/Main.saga)

Update imports:

```
import SagaJson as J (Json)
import SagaJson.Decode as D
```

Replace existing `J.string`, `J.int`, `J.at`, `J.field`, `J.list_of`, `J.nullable`, `J.parse` call sites with `D.string`, `D.int`, etc. The `J` alias still gives access to `Json` and `parse_string` if needed.

### Tests / acceptance

1. The project compiles after the split.
2. `src/Main.saga` runs and produces the same output as before the split (all the `dbg` calls in `main ()` should be byte-identical).
3. The empty `SagaJson.Encode` module exists and can be imported (even if it exports nothing useful yet).

### Out of scope

- No new functionality. This is a pure refactor.
- Don't rename any decoders. Move them as-is. Renames can happen later if needed.
- Don't introduce the `ToJson` or `FromJson` traits yet. Those are Phase 2 and Phase 5.

---

## Phase 1: Encoder primitives + renderer

**Goal:** Construct `Json` values directly and serialize them to strings. No traits, no Generic. Validates round-tripping against the existing parser.

**Why first:** Smallest unit of useful work. Everything else builds on these primitives. Surfaces any latent issues with `Value` / `Json` before more code depends on them.

### Deliverables

In `lib/SagaJson/Encode.saga` (created in Phase 0):

```
pub fun string : String -> Json
pub fun int    : Int -> Json
pub fun float  : Float -> Json    # non-finite (NaN/Inf) coerced to null
pub fun bool   : Bool -> Json
pub val null   : Json
pub fun array  : List Json -> Json
pub fun object : List (String, Json) -> Json

pub fun render : Json -> String
```

All constructors except `float` are one-liners wrapping the corresponding `Value` case. `float` checks `Float.is_finite` and produces `Json VNull` for non-finite inputs — matches JS / Rust serde / aeson behavior. Output is always valid JSON; the `render` function stays pure (no effect row).

`render` walks the `Value` tree and produces a compact (no whitespace) JSON string.

Now both `Encode.string` and `Decode.string` coexist cleanly. User code:

```
import SagaJson.Encode as E
import SagaJson.Decode as D

E.string "Alice" : Json          # encoder primitive
D.string j       : String        # decoder primitive
```

### `render` requirements

- Output is valid JSON parseable by `parse_string`.
- Strings: byte-level walk over the input (via `BS.from_string`), emit:
  - `\"` for `"`
  - `\\` for `\`
  - `\n` `\r` `\t` `\b` `\f` for those control chars (inverse of `escape_byte` in [lib/Parser.saga](../../../lib/Parser.saga))
  - `\u00XX` for other bytes `< 0x20`
  - All other bytes (including high-bit UTF-8 continuation bytes) pass through verbatim
- Numbers: use `show` (Int / Float Show instances). For non-finite floats, see `E.float` below — they're coerced to `null` at construction time, so `render` never sees a `VFloat NaN` or `VFloat Infinity`.
- Arrays: `[` items separated by `,` `]`. Empty array: `[]`.
- Objects: `{` `"key":value` pairs separated by `,` `}`. Empty object: `{}`. Key strings get the same escaping as value strings.
- No spaces, no newlines.

### Tests / acceptance

Add to [src/Main.saga](../../../src/Main.saga) a section that:

1. Builds a `Json` value by hand using `E.string`, `E.int`, `E.object`, `E.array`, etc., calls `E.render`, prints result.
2. Round-trip: `J.parse_string user_json` → `E.render` → parse the result again → verify equal to the first parse. Whitespace differences are expected; structural equality of `Json` values is what we check.
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

In `lib/SagaJson/Encode.saga`:

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

pub fun serialize : a -> String where {a: ToJson}
serialize x = render (to_json x)
```

Note: `to_json` has no effect row. Encoding cannot fail.

Phase 2 ships the single-method trait with signature `a -> Json` (no Options). Phase 4 grows it to the two-method shape from [examples/99k](../../../../saga/examples/99k-generic-derived-defaults.saga) — `to_json_with : Options -> a -> Json` plus the default-bodied `to_json : a -> Json`. This is a breaking change but only to library-internal call sites — manageable given the library is pre-1.0.

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

In `lib/SagaJson/Encode.saga`:

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

**Goal:** `deriving (ToJson)` works for user records and ADTs. `Options` unlocks Tier 2's "derive-with-knobs" middle ground. `to_json` grows an Options parameter, becoming the single Generic-aware entry point.

**Depends on:**

- Phases 1–3 complete.
- **Compiler:** Generic auto-derived for records and ADTs and `deriving (UserTrait)` synthesizes the delegating + bridge impls. See the [Generic Deriving guide](../../../../../saga-website/app/content/guide/generic-deriving.md) for the synthesized shape.

This phase cannot start until that is in place. Verify before kicking off implementation by checking that the example in the guide compiles and runs.

### Deliverables

All Phase 4 code goes in `lib/SagaJson/Encode.saga`.

**First, grow the `ToJson` trait** to the two-method shape from [examples/99k](../../../../../saga/examples/99k-generic-derived-defaults.saga):

```
pub trait ToJson a {
  fun to_json_with : Options -> a -> Json
  fun to_json      : a -> Json
  to_json x = to_json_with default_options x
}
```

Update every Phase 2 impl to provide `to_json_with` (and inherit `to_json` from the default body). Primitive impls ignore Options (`to_json_with _ s = string s`), container impls thread it (`to_json_with opts xs = array (List.map (to_json_with opts) xs)`).

Add layer-3 helpers (default-options + Options-taking variants of `serialize` / `deserialize`):

```
pub fun serialize      : a -> String                           where {a: ToJson}
pub fun serialize_with : Options -> a -> String                where {a: ToJson}
serialize      x      = render (to_json x)
serialize_with opts x = render (to_json_with opts x)
```

Add the derive-then-tweak escape hatch helper:

```
pub fun derive_with : Options -> a -> Json where {a: Generic a r, ToJson r}
derive_with opts x = to_json_with opts (to x)
```

**Then, eight Generic building-block impls**, matching the [Generic Deriving guide](../../../../../saga-website/app/content/guide/generic-deriving.md):

```
impl ToJson for U1                                          { ... }
impl ToJson for Leaf a    where {a: ToJson}                 { ... }
impl ToJson for Labeled a where {a: ToJson}                 { ... }
impl ToJson for Variant a where {a: ToJson}                 { ... }
impl ToJson for And l r   where {l: ToJson, r: ToJson}      { ... }
impl ToJson for Or l r    where {l: ToJson, r: ToJson}      { ... }
impl ToJson for Record a  where {a: ToJson}                 { ... }
impl ToJson for Adt a     where {a: ToJson}                 { ... }
```

`Record` emits `{` ... `}` and forwards inner; `Labeled` + `And` produce the `"key": value, "key": value` interior; `Variant` formats sum-constructor tags; `Adt` is usually pass-through but is the hook for sum-level framing.

Each impl provides `to_json_with` (inheriting `to_json` from the trait default). **Discipline:** inside building-block impls, always recurse via `to_json_with o`, never bare `to_json` — bare `to_json` drops options on the floor. This is exactly the pattern in [examples/99k](../../../../../saga/examples/99k-generic-derived-defaults.saga); follow it line-for-line.

```
# Options
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
```

There is no separate `generic_to_json` entry point. `to_json opts x` *is* the Generic-driven encoder when `x`'s type has `deriving (ToJson)`. The dispatch happens through the trait dict.

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
2. Add a Tier 2 example: hand-written impl on `User`, body `to_json_with opts u = Json.derive_with (Options { rename_all: CamelCase, ..opts }) u`. Verify camelCased output.
3. Add a Tier 2 example combining Generic with post-process combinators: `Json.derive_with opts u |> J.rename_field "manager" "supervisor"`.
4. Test an ADT with `deriving (ToJson)` — e.g., a `Role = Admin | Editor | Viewer` type — and verify the externally-tagged output.
5. Conflict rule: write a type with both `deriving (ToJson)` and a hand-written `impl ToJson for X` in the same module. Per the [guide](../../../../../saga-website/app/content/guide/generic-deriving.md), the hand-written impl wins silently. Verify by checking output matches the hand-written impl, not the derived shape.
6. **Options-threading regression test:** encode a deeply nested record (User → Address → Coords-like depth) via `Json.serialize_with (Options { rename_all: CamelCase, .. })` and assert that the *leaf-most* field name is camelCased. If any building-block impl accidentally recurses via bare `to_json` instead of `to_json_with`, this test fails — catching the footgun.

### Out of scope

- No attribute system. (Yes, even for `@json.rename`. Don't.)
- No per-field overrides in `Options`. (Yes, even tempting "just one little `field_renames: Map`." Don't.)
- No `FromJson` yet — Phase 5.

### Parallelizable subtasks

- Grow trait to two-method shape; update Phase 2 impls to `to_json_with` — agent A
- Rep building-block impls (8 of them) — agent A or B, after trait grows
- `Options` types + `default_options` + `derive_with` helper — agent C
- Name-style helpers (`camel_case : String -> String` etc.) — agent D, independent
- `Main.saga` examples (including the Options-threading regression test) — depends on all above

---

## Phase 5: `FromJson` + shared infrastructure

**Goal:** Symmetric decode path. Reuse `Options` knobs (the same `rename_all`, `tag_format`, etc. apply in reverse). Add post-process `refine` for decoders to handle invariants the schema can't express.

**Depends on:** Phase 4 complete.

### Deliverables

In `lib/SagaJson/Decode.saga` (alongside the existing decoder primitives moved there in Phase 0):

```
pub trait FromJson a {
  fun from_json_with : Options -> Json -> a needs {Fail Error}
  fun from_json      : Json -> a needs {Fail Error}
  from_json j = from_json_with default_options j
}

# Primitive + container impls mirroring ToJson on the Encode side

pub fun derive_from_with : Options -> Json -> a needs {Fail Error} where {a: Generic a r, FromJson r}
derive_from_with opts j = ...   # symmetric to Encode.derive_with

pub fun deserialize      : String -> Result a Error where {a: FromJson}
pub fun deserialize_with : Options -> String -> Result a Error where {a: FromJson}

pub fun refine : (a -> a needs {Fail Error}) -> (Json -> a needs {Fail Error}) -> Json -> a needs {Fail Error}
```

`refine` wraps a decoder and applies an extra invariant check (zod-style). Distinct from the current `Fail Error` short-circuit in that it post-processes a successfully decoded value.

`Options` is imported from `SagaJson.Encode` — it's shared. Some fields (e.g., `omit_nothing`) only make sense in one direction; document that.

### Tests / acceptance

1. Round-trip every type touched in Phase 4: encode with `to_json`, decode with `from_json`, verify equality.
2. With non-default `Options`, verify symmetry: `from_json options (to_json options x) == x` for the matching options on both sides.
3. `refine` example: a `User` with `age >= 0` invariant. Verify the refined decoder fails on negative ages with a clear error.

### Open questions to resolve in this phase

- How does the existing function-based `parse` / `run` API in `lib/SagaJson/Decode.saga` compose with the new trait? Probably `from_json` should *be* a decoder (`Json -> a needs {Fail Error}`), so `parse from_json some_string` works. Verify before designing.
- Where does `Options` live? Currently spec'd in `Encode`. Could move to `SagaJson` (shared root module) since both directions use it, or keep in `Encode` and have `Decode` import. Probably move to root for symmetry — decide here.
- `Options` unified vs split (`EncodeOptions` / `DecodeOptions`)? Lean unified; document irrelevant fields per direction.

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

# Serialization — Phased Implementation Plan

Companion to [../serialization.md](../serialization.md). That doc explains _what_ and _why_; this doc is _how_ and _when_. Agents picking up a phase should read both.

## Conventions for agents

- Read [../serialization.md](../serialization.md) before starting. Especially the "Why not attributes" and "Options" sections — there's design that's easy to violate without context.
- Module layout (current, post-Phase 5):
  - `lib/SagaJson.saga` — shared types (`Json` opaque type, `Error`), `parse_string` (neutral entry point), `Options` / `NameStyle` / `TagFormat` / `default_options`
  - `lib/Encode.saga` — encoder primitives, `render`, `ToJson` trait, building-block impls, layer-3 `serialize`/`serialize_with`, `derive_with`
  - `lib/Decode.saga` — function-based decoder primitives + combinators (`field`, `at`, `list_of`, `nullable`), `run`/`parse`; `FromJson` trait lands here in Phase 6
- Do **not** touch [lib/Parser.saga](../../../lib/Parser.saga). The parser is stable.
- Do **not** introduce attribute machinery (`@json.rename`, etc.). The decision is documented; don't relitigate it in code.
- Don't add `Options` fields beyond the ones spec'd in the design doc, even if tempted. Especially nothing per-field.
- After each phase, update [src/Main.saga](../../../src/Main.saga) with an example exercising the new API. The `Main.saga` examples are the integration test surface.
- Verify each phase compiles and runs (`saga run` or whatever the project entrypoint is — check [project.toml](../../../project.toml)). Report any compiler bugs encountered separately; don't paper over them.

### Language quirks worth knowing (carried forward from past phases)

- **Multi-line function calls inside `{ ... }` blocks are layout-sensitive.** Continuation args at the same indent as the function name parse as separate statements. Symptom: misleading "type mismatch: expected X, got Unit" pointing at the test-entry import. Fix: keep on one line, parenthesize, or split via `let`.
- **Record-update shorthand is `{ base | field: value }`**, NOT `{ ..base, field: value }`.
- **Trait methods are called bare** (`to_json x`), not qualified. To enable bare resolution from another module, import the trait: `import SagaJson.Encode (ToJson)`.
- **`Generic a r` constraints** on impl declarations use the bare form; on a `fun foo where {...}` clause, use `a: Generic r`.
- **Impl headers need explicit kind annotations for `Symbol` params.** `impl Trait for Variant n a where {n: KnownSymbol, ...}` is rejected with "kind mismatch: n has kind Star." Must write `impl Trait for Variant (n : Symbol) a where {n: KnownSymbol, ...}`. (Phase 5)
- **Trait default bodies don't resolve free names across modules.** If a trait declared in `M` has a default body referencing `some_value_from_M`, callers in other modules see `undefined variable` because the default body is re-elaborated at each impl-site without `M`'s lexical scope. Workaround: fully-qualify with the absolute module path (`SagaJson.default_options`, not aliased `J.default_options`). (Phase 5)

## Phase dependency graph

```
Phase 0 (module split: Encode / Decode)            DONE
   ↓
Phase 1 (encoder primitives + render)              DONE
   ↓
Phase 2 (ToJson trait + primitive/container impls) DONE
   ↓
Phase 3 (post-process combinators)                 DONE
   ↓
Phase 4 (Generic integration)                      DONE
   ↓
Phase 5 (Symbols migration + cleanup)              DONE
   ↓
Phase 6 (FromJson + shared infrastructure)
```

Phases 0–3 shipped before any compiler work landed. Phase 4 shipped against the compiler's first Generic-deriving release. Phase 5 migrates Encode to the type-level-Symbol representation of `Labeled` / `Variant` (compiler change landed mid-2026-05) — this is a prerequisite for correct sum-type FromJson decoding in Phase 6. Phase 6 adds FromJson on top of the migrated foundation.

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

## Phase 4: Generic integration — **DONE**

**Status:** Shipped. All four `TagFormat` variants implemented; tests in
[tests/DerivingTest.saga](../../../tests/DerivingTest.saga) cover derived records,
externally-tagged ADTs (unit / single-arg / multi-arg), recursive types, the
Options-threading regression, all five `NameStyle` variants, `omit_nothing`,
and all four `TagFormat` variants. 151 tests passing project-wide.

The notes below preserve the original phase plan for context. Two pieces of
the original plan diverged from what shipped:

- **Test 5 (conflict rule) was omitted.** The compiler raises `duplicate impl`
  when a type has both `deriving (ToJson)` and a hand-written `impl ToJson for T`.
  The Generic Deriving guide and serialization design doc previously promised
  silent precedence; we resolved the mismatch in favor of the hard error
  (silent precedence would let a derive sneak in under an existing manual impl
  with no signal). Both docs updated.
- **Tag formats were originally split into "implement now" and "Phase 4.x
  follow-up".** That follow-up landed in the same phase. All four formats
  (`ExternallyTagged`, `AdjacentlyTagged`, `InternallyTagged`, `Untagged`) work
  end-to-end. `InternallyTagged` falls back to externally-tagged for primitive
  / array payloads (matches serde's restriction; documented on `TagFormat`).

---

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

**Then, the four-trait Generic dispatch.** See the design doc's "Why four traits" section for rationale — short version: producing a Json AST (vs string fragments) means building blocks need to know which syntactic position they're in. Single-trait approaches (singleton-wrapping, role-method) require either runtime shape-sniffing or convention-enforced invariants. Four traits gives compile-time enforcement via non-overlapping helper traits — the same pattern GHC.Generics uses (`K1` / `M1` / `:+:` / `:*:`) and that aeson follows.

Trait definitions (only `ToJson` is `pub`):

```
pub trait ToJson a {
  fun to_json_with : Options -> a -> Json
  fun to_json      : a -> Json
  to_json x = to_json_with default_options x
}

trait ToJsonFields a {
  fun to_fields : Options -> a -> List (String, Json)
}

trait ToJsonArgs a {
  fun to_args : Options -> a -> List Json
}

trait VariantPayload a {
  fun payload_json : Options -> a -> Json
}
```

Twelve impls total (some Rep types implement multiple helper traits — that's fine, no overlap):

```
# ToJson (assembles Json values, including a passthrough for Leaf in record-field position)
impl ToJson for Leaf a    where {a: ToJson}                                { ... }
impl ToJson for Or l r    where {l: ToJson, r: ToJson}                     { ... }
impl ToJson for Record a  where {a: ToJsonFields}                          { ... }
impl ToJson for Variant a where {a: VariantPayload}                        { ... }
impl ToJson for Adt a     where {a: ToJson}                                { ... }

# ToJsonFields (record-interior dispatch)
impl ToJsonFields for Labeled a where {a: ToJson}                          { ... }
impl ToJsonFields for And l r   where {l: ToJsonFields, r: ToJsonFields}   { ... }

# ToJsonArgs (variant-arg-list dispatch)
impl ToJsonArgs for Leaf a where {a: ToJson}                               { ... }
impl ToJsonArgs for And l r where {l: ToJsonArgs, r: ToJsonArgs}           { ... }

# VariantPayload (variant payload by arity)
impl VariantPayload for U1                                                 { ... }
impl VariantPayload for Leaf a where {a: ToJson}                           { ... }
impl VariantPayload for And l r where {l: ToJsonArgs, r: ToJsonArgs}       { ... }
```

`Leaf a` participates in three traits — that's not overlap, those are three distinct traits with three distinct method names. The compiler picks the right impl based on which trait is required by the surrounding constraint.

What each role does:

- **`ToJsonFields`** — produces `List (String, Json)`. `Labeled` emits a single pair, `And` of two field-producers concats them. Consumed by `Record`, which wraps the result in a `VObject`.
- **`ToJsonArgs`** — produces `List Json`. `Leaf` emits a single value, `And` of two arg-producers concats them. Consumed by `VariantPayload` for multi-arg variants.
- **`VariantPayload`** — produces the Json that goes after the variant name. `U1` → null, `Leaf` → the unwrapped value, `And-of-Leaves` → a JSON array of the args.
- **`ToJson`** — the public trait. `Record` wraps fields, `Variant` emits `{name: payload}`, `Or` forwards to whichever side has the value, `Adt` is passthrough.

**Discipline:** inside building-block impls, always thread Options via `*_with opts` calls. Bare `to_json` (the default-options variant) drops Options on the floor — same footgun as before, same mitigation (regression test that encodes a deeply nested value with non-default options and asserts the leaf reflects them).

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

There is no separate `generic_to_json` entry point. `to_json opts x` _is_ the Generic-driven encoder when `x`'s type has `deriving (ToJson)`. The dispatch happens through the trait dict.

### Canonical default shape (locked here, hard to change later)

| Aspect            | Default                                                     |
| ----------------- | ----------------------------------------------------------- |
| Sum encoding      | `ExternallyTagged`                                          |
| Unit constructors | `{"Admin": null}` (do not specialize to bare strings in v1) |
| `Maybe Nothing`   | `null`                                                      |
| Field naming      | `AsIs` (use Saga field name unchanged)                      |

### Tests / acceptance

Update [src/Main.saga](../../../src/Main.saga):

1. Replace one of the existing hand-written `ToJson` impls (e.g., for `Coords`) with `deriving (ToJson)`. Verify output matches the hand-written version byte-for-byte.
2. Add a Tier 2 example: hand-written impl on `User`, body `to_json_with opts u = Json.derive_with (Options { rename_all: CamelCase, ..opts }) u`. Verify camelCased output.
3. Add a Tier 2 example combining Generic with post-process combinators: `Json.derive_with opts u |> J.rename_field "manager" "supervisor"`.
4. Test an ADT with `deriving (ToJson)` — e.g., a `Role = Admin | Editor | Viewer` type — and verify the externally-tagged output.
5. ~~Conflict rule: write a type with both `deriving (ToJson)` and a hand-written `impl ToJson for X`.~~ **Dropped:** the compiler raises `duplicate impl` instead of silently preferring the manual one. Design doc and Generic Deriving guide updated to match.
6. **Options-threading regression test:** encode a deeply nested record (User → Address → Coords-like depth) via `Json.serialize_with (Options { rename_all: CamelCase, .. })` and assert that the _leaf-most_ field name is camelCased. If any building-block impl accidentally recurses via bare `to_json` instead of `to_json_with`, this test fails — catching the footgun.

### Out of scope

- No attribute system. (Yes, even for `@json.rename`. Don't.)
- No per-field overrides in `Options`. (Yes, even tempting "just one little `field_renames: Map`." Don't.)
- No `FromJson` yet — Phase 5.

### Parallelizable subtasks

- Grow `ToJson` trait to two-method shape; declare helper traits (`ToJsonFields`, `ToJsonArgs`, `VariantPayload`, library-internal); update Phase 2 impls to `to_json_with` — agent A
- Building-block impls (12 of them across 4 traits) — agent A or B, after traits declared
- `Options` types + `default_options` + `derive_with` helper — agent C
- Name-style helpers (`camel_case : String -> String` etc.) — agent D, independent
- `Main.saga` examples (including the Options-threading regression test) — depends on all above

---

## Phase 5: Symbols migration + cleanup — **DONE**

**Status:** Shipped. `Labeled` and `Variant` building-block impls migrated to
the compiler's type-level Symbol representation; `Options` / `NameStyle` /
`TagFormat` / `default_options` moved to the root `SagaJson` module so both
Encode and Phase 6's FromJson can share them; `apply_name_style` re-anchored
on the Symbol-reflected source name. All 151 tests pass on the new
representation. `saga run src/Main.saga` output unchanged.

What shipped:

- `impl ToJsonFields for Labeled (n : Symbol) a where {n: KnownSymbol, a: ToJson}` —
  pattern is now `Labeled x`, name read via `symbol_name (Proxy : Proxy n)`.
- `impl ToJson for Variant (n : Symbol) a where {n: KnownSymbol, a: VariantPayload}` —
  pattern is now `Variant payload`, name read via `symbol_name`. The
  Symbol-reflected name is passed through `apply_name_style` before being
  emitted, matching the `Labeled` path (symmetric `rename_all` semantics).
- `VariantPayload` impls (U1, Leaf, And) unchanged — they don't carry the
  variant name; `Variant` reads its own symbol and threads the name into
  the final object / tag.
- Options + name-style + tag-format types moved verbatim to
  `lib/SagaJson.saga`; Encode imports them. Helper functions
  (`apply_name_style`, `snake_to_camel`, `capitalize`) stay in Encode for
  now — Phase 6 can pull them out if FromJson needs them.

Saga gotchas surfaced:

- **Impl headers need explicit kind annotations for non-Star type params.**
  `impl ToJson for Variant n a where {n: KnownSymbol, ...}` is rejected with
  `kind mismatch: type variable n has kind Star but trait KnownSymbol expects
kind Symbol`. The fix is to write the kind in the impl head:
  `impl ToJson for Variant (n : Symbol) a where {n: KnownSymbol, ...}`.
  The guide already shows this form; the spec example in the kickoff prompt
  elided it. Same shape for `Labeled (n : Symbol) a`.
- **Trait default-method bodies don't carry their lexical scope across
  module boundaries.** The `to_json` default body references `default_options`;
  when the trait is used from another module (`ToJsonTest`, `DerivingTest`),
  the compiler fails with `undefined variable: default_options` even though
  Encode imports it. Workaround: write the reference fully-qualified as
  `SagaJson.default_options` in the trait body. A short alias (e.g.
  `import SagaJson as J` + `J.default_options`) doesn't work — the qualifier
  has to be the absolute module name. Worth flagging to the compiler team:
  trait default bodies should resolve free variables at trait-declaration
  scope, not at impl-use scope.

What's next: Phase 6 (FromJson). Design decisions are pinned in the Phase 6
section below — do not relitigate (`Options` stays unified, `FromJsonFields`
is lookup-based, `FromJsonArgs` is positional with returned residue, sum
dispatch is name-based via `KnownSymbol`). The Symbol migration in this
phase is the prerequisite that makes the sum-type dispatch correct.

---

## Phase 5 (original spec — preserved for historical context)

**Goal:** Migrate the Encode building-block impls to the compiler's new type-level-Symbol representation of `Labeled` / `Variant`. Move `Options` to the shared root module. Lock in the symmetric `rename_all` source convention. This is a prerequisite for correct FromJson sum-type decoding in Phase 6 — without it, the synthesized `from` would wildcard variant names and `Or`'s left-bias would silently mis-decode any sum where variants share a payload shape (which includes enum-style ADTs like `Role = Admin | Editor | Viewer`).

**Why a separate phase:** The migration touches every Encode building-block impl that mentions `Labeled` or `Variant` (pattern shapes change, runtime name reads become symbol reflection, trait constraints grow `KnownSymbol`). Doing it in the same phase as FromJson would conflate two distinct lines of churn — the symbol migration is a "make the existing tests still pass on a new representation" exercise, while FromJson is "add a new direction." Separating them keeps each phase's diff focused.

**Depends on:** Phase 4 complete, and the compiler's Symbol/KnownSymbol release (mid-2026-05). Confirm before starting by verifying that `Labeled (n : Symbol) a` and `Variant (n : Symbol) a` from `Std.Generic` are the current shapes, and that `KnownSymbol` + `symbol_name (Proxy : Proxy n)` resolve.

### Required reading

1. [../serialization.md](../serialization.md) — design doc; especially "Why four traits" and the updated `Labeled` / `Variant` signatures in the Rep building-block list.
2. [Generic Deriving guide](../../../../../saga-website/app/content/guide/generic-deriving.md) — "Type-level names" section (~line 90) and the worked `ToJson` example showing the `n: KnownSymbol` constraint pattern.
3. [lib/Encode.saga](../../../lib/Encode.saga) — your migration target. The impls that need changes are listed under Deliverables below.

### Deliverables

**A. Migrate Encode building-block impls to type-level Symbols.**

Every impl that currently destructures a runtime name field on `Labeled` or `Variant` changes shape. Audit and update each:

| Old                                                   | New                                                                                 |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `impl ToJsonFields for Labeled a where {a: ToJson}`   | `impl ToJsonFields for Labeled n a where {n: KnownSymbol, a: ToJson}`               |
| `to_fields opts (Labeled name x) = ...`               | `to_fields opts (Labeled x) = { let name = symbol_name (Proxy : Proxy n); ... }`    |
| `impl ToJson for Variant a where {a: VariantPayload}` | `impl ToJson for Variant n a where {n: KnownSymbol, a: VariantPayload}`             |
| `to_json_with opts (Variant name p) = ...`            | `to_json_with opts (Variant p) = { let name = symbol_name (Proxy : Proxy n); ... }` |

The `VariantPayload` building-block impls (currently on `U1`, `Leaf a`, `And l r`) do not carry the variant name — `Variant` reads its own symbol and threads the name down into `object [(name, payload_json p)]`. Verify that no `VariantPayload` impl needs the symbol; if one does, surface it before improvising.

All other impls (`Leaf`, `And`, `Or`, `Record`, `Adt`, `U1`, primitives, containers) are unaffected.

**B. Move `Options` to `lib/SagaJson.saga` (root module).**

Currently defined in `lib/Encode.saga` lines 112–149 (`NameStyle`, `TagFormat`, `Options`, `default_options`). Move them verbatim to the root module. Update `lib/Encode.saga` to import from `SagaJson`. Phase 6 will import the same definitions for FromJson. Rationale: neither direction owns `Options`; it's shared infrastructure.

**C. Lock in the `rename_all` source convention.**

Symbols reflect to the source identifier as written in the Saga source (e.g., field `user_id` reflects to `"user_id"`). Document that the library treats this as the canonical input to `rename_all`. The library _applies_ `rename_all` to the source name to produce the output key on encode (and the expected input key on decode in Phase 6). Source convention is snake_case by Saga style; users who write `user_id` and want output `userId` use `Options { rename_all: CamelCase, .. }`.

Pin this in the design doc's `rename_all` section. The semantic is now symmetric and meaningful in both directions.

**D. Update tests.**

[tests/DerivingTest.saga](../../../tests/DerivingTest.saga) (24 tests from Phase 4) currently tests against the old value-level-name building-block shape. Pattern matches in any helper or assertion that mentions `Labeled name x` or `Variant name x` need updating. Run the full suite (`saga test`) to confirm — the 151-test baseline must still pass when migration is done.

**E. Sanity-check hand-written impls.**

Existing hand-written impls in [src/Main.saga](../../../src/Main.saga) (Coords, Address, User, Role) don't touch `Labeled` or `Variant` directly — they go through the public `ToJson` trait. They should be unaffected, but verify by running `saga run`.

### Out of scope for Phase 5

- **No FromJson code.** That's Phase 6. Resist the urge to "start sketching the symmetric impl while I'm in here." The migration is its own deliverable.
- **No new Options fields.** The set is locked.
- **No attribute system.** Still no.
- **No public-API changes.** Users calling `serialize` / `serialize_with` / `derive_with` should see byte-identical output before and after migration. If anything user-visible changes, that's a regression to investigate.

### Tests / acceptance

1. All 151 existing tests pass (`saga test`). No new tests required for this phase — passing the existing suite on the migrated representation IS the acceptance criterion.
2. `saga run src/Main.saga` produces output byte-identical to the pre-migration version. (Encode hasn't changed semantically; only the internal representation it dispatches against.)
3. The Options-threading regression test from Phase 4 (deeply-nested record with `rename_all: CamelCase`) still asserts correctly on the leaf field name.

### When to stop and ask

- Any impl where the migration isn't a mechanical rewrite — i.e., the new shape needs structurally different logic, not just `symbol_name` substitution. That's a signal we missed something in the design.
- Compiler errors that suggest `KnownSymbol` resolution isn't firing where expected. Possible interaction with the trait dispatch we want to flag.
- Any test that breaks in a way the migration shouldn't have caused. Likely a separate bug; surface before working around.

### Parallelizable subtasks

The migration is sequentially small enough that one agent does it in one pass. Order:

1. Move `Options` to root module (B). Update Encode's imports.
2. Migrate the Labeled / Variant building-block impls (A).
3. Run the test suite, fix breakage (D).
4. Verify Main.saga output unchanged (E).
5. Update the design doc's `rename_all` section + the `Labeled` / `Variant` signature blocks (C, plus any doc-prose that mentions value-level names).

---

## Phase 6: `FromJson` + shared infrastructure — **DONE**

**Status:** Shipped. `FromJson` trait + three library-internal helper
traits (`FromJsonFields`, `FromJsonArgs`, `FromVariantPayload`) added to
`lib/Decode.saga` alongside the existing function-based decoder
primitives. All 12 building-block impls implemented mirroring Encode's 12. Layer-3 helpers `deserialize`, `deserialize_with`, `derive_from_with`,
`refine` exported. `apply_name_style` + helpers moved to root
`lib/SagaJson.saga` so both directions share them. 170 tests passing
(151 baseline + 19 new in `tests/FromJsonTest.saga`).

What shipped:

- `pub trait FromJson a` with two-method shape (`from_json_with` +
  default-bodied `from_json`). Default body fully-qualifies
  `SagaJson.default_options` per the Phase 5 trait-default-scoping
  workaround.
- `FromJsonFields` is lookup-based: each `Labeled n a` impl independently
  reflects its symbol via `KnownSymbol`, applies `apply_name_style`, and
  looks up the resulting key in the input field list. `And` for
  `FromJsonFields` runs both sides against the same input list.
  Missing-field failures land naturally at the `Labeled` level.
- `FromJsonArgs` is positional with returned residue: `Leaf` consumes one
  item from the head of the list; `And` chains via the residue.
- `FromVariantPayload` dispatches by Json shape: `U1` ← `VNull`, `Leaf` ←
  single value, `And-of-args` ← `VArray` unfolded via `FromJsonArgs`.
- `Variant n a`'s `FromJson` impl reflects the expected symbol, applies
  `rename_all`, and decodes per `TagFormat` (Externally / Adjacently /
  Internally / Untagged). `Or`'s try-left-fall-back-to-right impl walks
  the variant chain correctly because tag mismatches genuinely fail.
- `refine` is a one-liner that post-applies an invariant check on a
  decoder's output. Tested with a `User { age: Int }` + `age >= 0`
  invariant.
- `Options` stays unified (no `EncodeOptions`/`DecodeOptions` split).
  `omit_nothing` is encode-only — documented on the docstring.
- `lib/Encode.saga` untouched apart from the helper-import shuffle.
  `lib/Parser.saga` untouched. The function-based `parse` / `run` API
  stays for ad-hoc decoders.

Tests in [tests/FromJsonTest.saga](../../../tests/FromJsonTest.saga)
cover: primitive/container round-trips, flat & nested derived records
(Coords, Address, User), the headline sum-type case (Role: every
variant round-trips, proving the Symbol-based `Variant` impl
discriminates), unit/single-arg/multi-arg ADT (Shape), Options symmetry
(rename_all: CamelCase encodes and decodes), tag-mismatch failure,
missing-field failure, wrong-typed field failure, and the `refine`
happy path + failure path. [src/Main.saga](../../../src/Main.saga)
gains a derived round-trip demo on `Account` via `deserialize`.

Compiler bugs surfaced and filed in
`/home/dylan/projects/saga/examples/bugs/effectful-trait-self-dispatch/`
(all fixed mid-phase; tracked here for context):

1. **Trait method declared with `needs {Fail Err}` lost its effect on
   recursive trait dispatch.** A building-block impl that called the same
   trait method on a sub-component compiled, but at runtime hit
   `function called with N arguments, but expects N+1` because the
   handler arg wasn't threaded through the recursive call. Affected
   every `Leaf`/`Labeled`/`And`/`Or` impl in `FromJson`. Fixed.
2. **Compiler-synthesized impls from `deriving (FromJson)` didn't carry
   `needs {Fail Error}`.** Synthesis copies the trait method shape but
   omitted the effect row, so the synthesized bridge for any
   `record/type T deriving (FromJson)` failed elaboration with "uses
   effects but has no 'needs' declaration." Fixed.
3. **Cross-trait dispatch from inside a `with { fail ... = ... }`
   handler body that closes over a let-bound `symbol_name`-derived
   value.** Hit the same `function called with N, expects N+1` PANIC.
   Inlining a literal where the handler used the let binding made the
   same impl work, isolating the trigger to the let-capture path.
   Affected `FromJsonFields for Labeled` (every derived record decode).
   Fixed.

Saga gotchas surfaced (worth carrying forward):

- **Effectful trait methods need `needs {…}` on both the trait
  declaration and each impl head.** The trait declaration's `needs`
  describes the method's signature; the impl head's `needs` describes
  what the impl body actually uses. They have to align.

---

## Phase 6 (original spec — preserved for historical context)

**Goal:** Symmetric decode path. Reuse `Options` knobs (the same `rename_all`, `tag_format`, etc. apply in reverse). Add post-process `refine` for decoders to handle invariants the schema can't express. Sum-type decoding is correct because Phase 5's Symbol migration made `Variant n a` discriminable by `n`.

**Depends on:** Phase 5 complete.

### Deliverables

In `lib/Decode.saga` (alongside the existing function-based decoder primitives that have been there since Phase 0):

```
pub trait FromJson a {
  fun from_json_with : Options -> Json -> a needs {Fail Error}
  fun from_json      : Json -> a needs {Fail Error}
  from_json j = from_json_with default_options j
}

# Primitive + container impls mirroring ToJson on the Encode side
# (String, Int, Float, Bool, List a, Maybe a)

# Helper traits — library-internal, not pub.
trait FromJsonFields a {
  fun from_fields : Options -> List (String, Json) -> a needs {Fail Error}
}

trait FromJsonArgs a {
  fun from_args : Options -> List Json -> (a, List Json) needs {Fail Error}
}

trait FromVariantPayload a {
  fun decode_payload : Options -> Json -> a needs {Fail Error}
}

# Building-block impls (mirror Encode's 12, with the right helper trait per position)

pub fun derive_from_with : Options -> Json -> a needs {Fail Error}
  where {Generic a r, FromJson r}

pub fun deserialize      : String -> Result a Error where {a: FromJson}
pub fun deserialize_with : Options -> String -> Result a Error where {a: FromJson}

pub fun refine : (a -> a needs {Fail Error})
              -> (Json -> a needs {Fail Error})
              -> Json -> a needs {Fail Error}
```

### Design decisions

- **`FromJsonFields` is lookup-based, not positional-with-state.** Each `Labeled n a` impl independently calls `symbol_name`, applies `rename_all` (using `Options`), looks up the resulting key in the input field list, and decodes. `And` for `FromJsonFields` runs both sides against the same input list. Order-independent, missing-field failures land naturally.
- **`FromJsonArgs` stays positional.** Variant args are inherently ordered (`Rect 1.0 2.0`). `from_args` returns the decoded value paired with the remaining unconsumed input list; `And` chains them via the returned residue.
- **Sum dispatch is name-based.** `Variant n a`'s impl reflects its expected symbol via `KnownSymbol`, checks against the input tag, and fails if they don't match. `Or`'s try-left-fallback-to-right pattern then walks the variant chain correctly because mismatched branches now genuinely fail (which they didn't pre–Phase 5).
- **Coexistence with `parse` / `run`.** Both APIs stay. `deserialize` is the trait-based entry point. `parse` and `run` (function-based decoders) remain for ad-hoc cases where the user doesn't want to define a type.
- **`Options` is in `lib/SagaJson.saga`** (moved there in Phase 5). FromJson imports from root.
- **`Options` stays unified** (no `EncodeOptions` / `DecodeOptions` split). `omit_nothing` is encode-only and documented on the field as such.

### `refine`

```
pub fun refine : (a -> a needs {Fail Error})
              -> (Json -> a needs {Fail Error})
              -> Json -> a needs {Fail Error}
```

Wraps a decoder and applies an extra invariant check (zod-style). Distinct from `Fail Error` short-circuit during decoding — it post-processes a successfully decoded value to enforce invariants the type system can't express. Example: a `User` with `age >= 0`.

### Tests / acceptance

In `tests/FromJsonTest.saga` (mirror `tests/DerivingTest.saga`):

1. **Round-trip every type from Phase 4's demos:** encode with `to_json`, decode with `from_json`, verify equality. Includes the `Role` enum — this is the test that proves sum-type decoding works.
2. **Options symmetry:** `from_json_with opts (to_json_with opts x) == x` for non-default `Options` (camelCase rename_all on a nested record). Encode and decode use the same Options; round-trip preserves the value.
3. **Tag-mismatch failure:** decode `{"NotAVariant": null}` as `Role`. Expect a clean `Fail Error` from `Or` exhausting both branches with no name match.
4. **Missing-field failure:** decode `{"name": "Alice"}` as a record requiring both `name` and `age`. Expect a clean failure naming the missing field.
5. **`refine` example:** `User { age: Int }` with invariant `age >= 0`. Refined decoder fails on negative ages with a useful error.
6. **All 151 existing tests still pass** (the Phase 5 → Phase 6 regression bar).

### Out of scope

- No attribute system.
- No per-field Options knobs.
- No `JsonCodec` single-trait shortcut.
- No changes to `lib/Encode.saga` unless `Options`-related (which should be settled in Phase 5).

### Parallelizable subtasks

- FromJson trait declaration + helper traits + primitive/container impls — agent A
- Building-block impls (~12, mirroring Encode) — agent B, after agent A declares traits
- Layer-3 helpers (`deserialize`, `deserialize_with`, `derive_from_with`, `refine`) — agent C, depends on traits
- Tests + Main.saga round-trip demo — depends on all above

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

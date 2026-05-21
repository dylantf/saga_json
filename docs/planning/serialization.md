# JSON Serialization — Design Notes

Status: planning. Depends on Generic landing in the compiler (see `saga/examples/99-generic-spike.saga`).

## Scope

Add encoding to `saga_json`. Currently the library only decodes (`Json -> a needs {Fail Error}`). We need the symmetric direction: `a -> Json`, plus rendering `Json -> String`.

## Module layout

The library splits into three modules to keep encoder/decoder namespaces from colliding (both have a `string`, an `int`, etc.):

```
SagaJson           # shared: Json opaque type, Error, parse_string
SagaJson.Encode    # encoder primitives, render, ToJson trait, Options, serialize, derive_with
SagaJson.Decode    # decoder primitives, combinators, FromJson trait, deserialize, refine
```

Users typically alias both:

```
import SagaJson as J (Json)
import SagaJson.Encode as E
import SagaJson.Decode as D
```

`Encode` and `Decode` both import `SagaJson` (for `Json`/`Error`) and `SagaJson.Parser` (for `Value`); neither imports the other. No circular import risk.

This layout matches Elm (`Json.Encode` / `Json.Decode`), aeson (`ToJSON` / `FromJSON`), and serde (`Serialize` / `Deserialize`). Convergent design.

## Library-only work

No language features are blocked. The library needs:

### Encoder primitives

Thin wrappers over the existing `Value` constructors, all returning `Json`:

```
pub fun string : String -> Json
pub fun int    : Int -> Json
pub fun float  : Float -> Json    # NaN/Infinity coerced to null
pub fun bool   : Bool -> Json
pub fun null   : Json
pub fun array  : List Json -> Json
pub fun object : List (String, Json) -> Json
```

`float` coerces non-finite values to `null` at construction time. Matches JS `JSON.stringify`, Rust serde, Haskell aeson — JSON doesn't have NaN or Infinity, so the choice is "produce invalid JSON," "fail at encode time," or "silently coerce to null." Industry convergent behavior is the third. This keeps `render` a pure `Json -> String` (no effect row) and preserves the invariant that anything in the `Json` AST renders as valid JSON.

### Renderer

`render : Json -> String`, walks the `Value` AST.

- Numbers: `show` (Int / Float Show instances)
- Strings: byte-level escape over `BS.from_string`, mirroring `escape_byte` in `Parser.saga:55-64`
- UTF-8 passes through verbatim; escape only control chars, `"`, `\`
- Compact output first; pretty-printing later if needed

### Trait

```
trait ToJson a {
  fun to_json_with : Options -> a -> Json
  fun to_json      : a -> Json
  to_json x = to_json_with default_options x
}
```

This is the two-method pattern from [examples/99k-generic-derived-defaults.saga](../../../../saga/examples/99k-generic-derived-defaults.saga). The trait gives library code an Options-threaded routed method (`to_json_with`) and gives users a convenience wrapper (`to_json`) with a default body that forwards to `to_json_with default_options`. Hand-written impls only need to provide `to_json_with`; the default body for `to_json` is inherited.

`to_json_with` is the real method — it gets Options threaded through and is what `deriving` synthesizes against and what the building-block impls call recursively. Users almost never call `to_json_with` directly; they call `to_json p` for the default shape or `Json.serialize_with opts p` for a tweaked shape.

Discipline (one rule): **inside any building-block impl, recurse via `to_json_with o`, not bare `to_json`.** Bare `to_json` drops options on the floor. This is mechanical — there are 8 building-block impls, all touched once. A regression test that encodes a deeply nested value with non-default options and asserts the leaf reflects them will catch any violation.

Encoders are plain functions, no effect row. Encoding cannot fail in any honest way.

Library impls: `String`, `Int`, `Float`, `Bool`, `List a where ToJson a`, `Maybe a where ToJson a`, plus the Generic Rep building blocks (`U1`, `Leaf`, `Labeled`, `Variant`, `And`, `Or`, `Record`, `Adt`).

Note: Phases 1–3 ship with just `to_json : a -> Json` (no Options anywhere). Phase 4 grows the trait to the two-method shape, adds `Options` + `default_options`, and updates all impls. Cleaner phasing than shipping the full shape with a stub Options earlier.

### The three-layer API

User-facing functions split across three layers, each addressing a real boundary:

```
# Layer 1: typed value <-> Json AST (trait methods)
fun to_json        : a -> Json                              where {a: ToJson}    # default opts
fun to_json_with   : Options -> a -> Json                   where {a: ToJson}    # custom opts
fun from_json      : Json -> Result a Error                 where {a: FromJson}  # default opts
fun from_json_with : Options -> Json -> Result a Error      where {a: FromJson}  # custom opts

# Layer 2: Json AST <-> String (pure structural conversion, no Options)
pub fun render       : Json -> String
pub fun parse_string : String -> Result Json Error   # already exists

# Layer 3: typed value <-> String (the everyday API)
pub fun serialize      : a -> String                              where {a: ToJson}
pub fun serialize_with : Options -> a -> String                   where {a: ToJson}
pub fun deserialize      : String -> Result a Error               where {a: FromJson}
pub fun deserialize_with : Options -> String -> Result a Error    where {a: FromJson}
```

`serialize` and `deserialize` use `default_options` via the trait's default `to_json` / `from_json` methods. The `_with` variants take Options explicitly.

Usage by user type:

- **Day-1 user:** `Json.serialize user` and `Json.deserialize input_string`. Sees only layer 3.
- **Whole-record tweaks:** `Json.serialize_with my_opts user`.
- **Targeted shape edits:** drops to layers 1+2 — `to_json_with opts u |> rename_field ... |> render`.
- **Library author writing impls:** implements `to_json_with` (layer 1). Inherits `to_json` from the trait default. Never touches the other layers.
- **`deriving` machinery:** synthesizes against layer 1's `to_json_with`.

Three is the convergent number across Elm, serde, and aeson — the three boundaries (typed ↔ AST, AST ↔ bytes, typed ↔ bytes) are real and worth naming separately.

### `Json.derive_with` — the derive-then-tweak escape hatch

For the case where a user writes a manual `impl ToJson for User` *and* wants to start from the Generic-derived encoding (then post-process), there has to be a way to invoke the derived encoding from inside the manual impl. The trait dispatch can't — manual wins and shadows the derived.

The library provides a thin helper:

```
pub fun derive_with : Options -> a -> Json where {a: Generic a r, ToJson r}
derive_with opts x = to_json_with opts (to x)
```

Naming mirrors `to_json_with` — `_with` consistently signals "this is the Options-taking variant." Call site:

```
impl ToJson for User {
  to_json_with opts u = Json.derive_with opts u
    |> J.rename_field "id" "userId"
}
```

Reads as "to_json with opts: derive with opts, then rename." This is the only path for "derive defaults then tweak per field" without going fully hand-built.

(Symmetric helper for FromJson is TBD in Phase 5 — likely `Json.derive_from_with` or just overloading `derive_with` by direction.)

## Generic & deriving

Once compiler-side Generic lands and is auto-derived for all types, users get `deriving (ToJson)` and a delegating impl is synthesized. The library provides ToJson impls for the Rep building blocks; the compiler-synthesized delegating impl bridges user types to those.

Reference: [Generic Deriving guide](../../../../saga-website/app/content/guide/generic-deriving.md).

### Why four traits (the no-overlap pattern)

For string-output deriving (à la [examples/99k](../../../../saga/examples/99k-generic-derived-defaults.saga)), a single `ToJson` trait works because every level just `<>`s string fragments together. For a real `Json` AST output, the building blocks need to know which *syntactic position* they're in: are we producing object fields, positional arguments, or a standalone value? Same Json shape can mean different things.

The clean solution is the same one GHC.Generics uses: **multiple helper traits, one per syntactic position.** No overlapping instances, no runtime shape-sniffing, dispatch resolved at compile time by trait constraints.

```
pub trait ToJson a {                                # the user-facing trait
  fun to_json_with : Options -> a -> Json
  fun to_json      : a -> Json
  to_json x = to_json_with default_options x
}

trait ToJsonFields a {                              # library-internal, not pub
  fun to_fields : Options -> a -> List (String, Json)
}

trait ToJsonArgs a {                                # library-internal, not pub
  fun to_args : Options -> a -> List Json
}

trait VariantPayload a {                            # library-internal, not pub
  fun payload_json : Options -> a -> Json
}
```

Building-block impls each implement only the trait matching their position. Some Rep types appear in multiple positions and therefore implement multiple traits — that's fine; no overlap because the traits are distinct.

- `Leaf a where {a: ToJson}` → `ToJson` (passthrough — used when Leaf is inside Labeled in a record field)
- `Leaf a where {a: ToJson}` → `ToJsonArgs` (produces `[to_json x]` — used inside And in a multi-arg variant)
- `Leaf a where {a: ToJson}` → `VariantPayload` (unwraps the leaf — used as sole payload of a single-arg variant)
- `Labeled a where {a: ToJson}` → `ToJsonFields` (produces `[(name, to_json x)]`)
- `And l r where {l: ToJsonFields, r: ToJsonFields}` → `ToJsonFields` (concat fields)
- `And l r where {l: ToJsonArgs, r: ToJsonArgs}` → `ToJsonArgs` (concat args)
- `And l r where {l: ToJsonArgs, r: ToJsonArgs}` → `VariantPayload` (wraps `to_args` result in an array)
- `Or l r where {l: ToJson, r: ToJson}` → `ToJson` (forwards to whichever branch is present)
- `U1` → `VariantPayload` (returns `null`)
- `Record a where {a: ToJsonFields}` → `ToJson` (wraps fields in object)
- `Variant a where {a: VariantPayload}` → `ToJson` (emits `{name: payload}`)
- `Adt a where {a: ToJson}` → `ToJson` (passthrough)

Twelve impls total. Three on Leaf (one per trait it participates in), three on And, one each on the rest.

### What this is not

This is not a workaround for Saga's parser limitations. Saga doesn't accept `impl X for Variant U1` / `impl X for Variant (Leaf a)` / `impl X for Variant (And l r)` — but specializing on parameterized type shapes is what Haskell calls **overlapping instances**, and mature libraries deliberately avoid them. They have well-known problems: resolution ambiguity, fragile incremental compilation, confusing user error messages. aeson, GHC.Generics, and serde-derive all sidestep the problem the same way — multiple helper typeclasses with non-overlapping coverage. The four-trait pattern is the actual right answer for this kind of dispatch, not a hack.

### Why not singleton-wrapping or role-method

Two single-trait alternatives were considered:

- **Singleton-wrapping:** `Leaf x` wraps in a singleton VArray; `And` dispatches by inspecting whether children are VObject or VArray. Works but allocates per leaf, encodes Rep-position info into Json's shape (overloading the type), and the invariant ("no mixed shapes in And") is convention-enforced.
- **Role-method:** every `ToJson` impl carries a `role : a -> Role` method returning a tag (FieldFragment / PositionalValue / Standalone); `And` dispatches by examining roles. Works but adds a runtime branch per And, and the invariant is still convention-enforced.

Both have the same correctness model: works in the happy path, silently produces wrong output on misuse. The four-trait approach makes misuse a *compile error* (a building-block impl mismatched with its expected trait constraint). That's the genuine win, and it's worth four small library-internal traits.

There is no `deriving (Generic)` syntax. Generic is implied automatically when any user-defined derive is requested.

Saga also supports deriving traits whose methods mix to- and from- directions in one trait (e.g. a `JsonCodec` with both `encode : a -> Json` and `decode : Json -> Result a Error`). We'll stick with separate `ToJson` and `FromJson` traits per convention, but the option exists.

## The user-facing ladder

There are **two tiers**. Inside the manual tier, `to_json` itself (the trait method) is what users compose with — there's no separate `generic_to_json` helper.

### Tier 1: Derive

```
record User { ... } deriving (ToJson)
```

Compiler synthesizes the impl using the canonical defaults (see below). Zero ceremony.

### Tier 2: Manual impl

```
impl ToJson for User {
  to_json_with opts u = <anything : Json>
}
```

The body is a spectrum:

- `Json.derive_with opts u` — equivalent to Tier 1 (the derived encoding, via Generic)
- `Json.derive_with (Options { rename_all: CamelCase, ..opts }) u` — derived shape with uniform tweaks
- `Json.derive_with opts u |> <post-process combinators>` — derived shape with targeted shape edits
- `J.object [("name", J.string u.name), ...]` — hand-built from scratch
- Any mix

Tier 2 is one tier with a spectrum, not separate options. `Json.derive_with` is the bridge between manual impls and Generic-derived encoding (see the section above on the helper).

### Post-process combinators

Single-level operations on `Json`. Composed with `|>`; nesting matches data nesting through function composition. Operate on the runtime `Json` AST after `generic_to_json` has produced it.

```
J.update_field : String -> (Json -> Json) -> Json -> Json
J.rename_field : String -> String -> Json -> Json
J.remove_field : String -> Json -> Json
J.insert_field : String -> Json -> Json -> Json
J.map_object   : ((String, Json) -> (String, Json)) -> Json -> Json
```

Usage:

```
impl ToJson for User {
  to_json u = generic_to_json default u
    |> J.update_field "address" (fun addr ->
         addr
         |> J.remove_field "address2"
         |> J.rename_field "address1" "Address 1"
       )
    |> J.rename_field "password_hash" "passwordHash"
}
```

Missing keys: fail loudly (not silent no-op). A missing key is almost always a bug — typo or stale post-process after a field rename.

These combinators do not need Generic traversal. They operate on the `Json` value tree directly; each call names one key at one level; nesting is achieved by passing a lambda that operates on the nested `Json`.

## Composition

`deriving` does not recurse to generate impls for field types. It _requires_ each field type to have a `ToJson` impl in scope, resolved through trait constraints. Derived and manual impls coexist seamlessly:

```
record Address { ... }
impl ToJson for Address { ... }       # hand-written

record User { address: Address, ... }
  deriving (ToJson)                    # picks up the manual Address impl
```

This is the load-bearing part of the design. It means "I want a different shape for one type" rarely forces you to hand-write its containers — push the deviation down to the smallest type.

Newtype wrappers handle the "one field needs special encoding" case (e.g., `type IsoDate = IsoDate Date` with a manual `impl ToJson for IsoDate`).

## Options

`Options` is a value-level config record passed to `generic_to_json`. **Restricted to uniform policies only.** Anything that names a specific field belongs in a hand-written `J.object` impl.

Initial fields:

- `rename_all : NameStyle` — CamelCase, KebabCase, etc.
- `omit_nothing : Bool` — drop `Maybe` fields that are `Nothing`, vs. emit `null`
- `tag_format : TagFormat` — External / Adjacent / Internal / Untagged
- `tag_field : String`, `content_field : String` — for Adjacent

Resist adding `overrides : Map String (a -> Json)` or `field_renames : Map`. Those reinvent attributes as a stringly-typed record with worse type checking. The escape hatch for per-field control is dropping to hand-built `J.object`.

## Why not attributes

The previous draft of this doc treated attributes as "probably eventually, when pain demands it." Further thought makes that less likely — the position below is closer to "probably never, on principle."

### JSON is a stringly-typed boundary

JSON itself uses strings for keys. *Any* encoder is going to deal with strings somewhere — there's no way around it. The design question is whether that fact is buried in compiler metadata (attributes) or exposed as plain values (combinators on `Json`).

The dictionary case is the clincher. Consider:

```
record Config { features: Map String Bool, ... }
```

A `Map String Bool` field has string keys at runtime. No attribute can give typesafe rename for those keys, because the keys aren't compile-time known — there's no field to attach an attribute to. The only option is a runtime API:

```
features_renamed = J.map_object (fun (k, v) -> (camel_case k, v)) features
```

So attributes only solve *half* the problem: static field names. Dynamic keys still need combinators. Shipping attributes means **two ways to manipulate JSON keys depending on whether they're statically known** — an asymmetry baked into the language.

The consistent alternative: treat JSON keys as runtime strings everywhere. One API. Same combinators for record fields, dictionary keys, and ad-hoc shaping.

### What this stance gives up

- **Compile-time rename propagation.** Rename a Saga field, and the derived encoder emits the new name; any hand-written post-process referring to the old name silently drops to a no-op (mitigated by fail-loud on missing keys).
- **Field-rename metadata next to the field.** Renames live in the impl, not on the record. The impl is the encoder's source of truth.

Mitigations: round-trip tests, fail-loud combinators, treating `to_json` as part of the schema contract that's hand-maintained on field changes. This is what Elm/aeson code looks like in practice — workable.

### What it buys

- One mental model: static fields and dynamic keys use the same API
- Encoders are values, not metadata — composable, refactorable, generatable
- No second mini-language to learn, document, or evolve
- Saga's "everything is a value" identity stays intact at this boundary

### Caveat: typed field references

The one future development that could change the calculus: if Saga grows first-class field references (some kind of `User.address` as a typed value, useful for record updates / lens-like access / printf-style formatters / ORM builders), then post-process combinators could accept those instead of strings — `J.update_field User.address ...` — and you'd recover compile-time rename safety for the record-field case without inventing attributes. That's a bigger language feature with broader payoff than JSON; worth keeping the door open but not driving its design.

## Canonical default shape

Decisions baked into `deriving (ToJson)` with default Options. These are sticky — every derived encoder in the ecosystem will lock them in, so pick carefully.

| Decision          | Default                                                 | Notes                                        |
| ----------------- | ------------------------------------------------------- | -------------------------------------------- |
| Sum encoding      | Externally tagged: `{"Move": {...}}`                    | Only format that round-trips arbitrary sums  |
| Unit constructors | `{"Admin": null}`                                       | Could specialize to bare `"Admin"`; pick one |
| `Maybe` fields    | Emit `null` for `Nothing`                               | Symmetric with decoding, lossless            |
| Field naming      | Use record field names as-is (snake_case)               | `rename_all` handles foreign APIs            |
| Float formatting  | TBD — needs decision; printf-`%g` is good enough for v1 | Shortest round-trip is a project unto itself |

## Conflict rule

If a type has both `deriving (ToJson)` and a hand-written `impl ToJson for Foo`, **the compiler raises `duplicate impl`.** To override the default encoding, drop the `deriving (ToJson)` clause and keep only the manual impl. (Earlier drafts of this doc described silent override; that was a documentation mismatch with the compiler, resolved in favor of the hard error — silent precedence would let a derive sneak in under an existing manual impl with no signal.) If you want the derived shape as a starting point inside a manual impl, call `Json.derive_with opts x`.

## Dependencies on the compiler

Before this design works end-to-end:

1. Generic auto-derived for records and ADTs (Phase 3 of the compiler spike)
2. `deriving (ToJson)` synthesizes the delegating impl `impl ToJson for T { to_json u = to_json (to u) }`
3. Trait method default implementations — so `deriving (ToJson)` can emit `impl ToJson for T {}` and inherit the default `to_json = generic_to_json default_options`. Without defaults, every derived impl spells out the call site. Workable but uglier.

## Open questions

- Float rendering precision / format
- Whether `ToJson` for sums-of-units (enum-like ADTs) should specialize to bare strings
- `FromJson` is the symmetric problem and will reuse the same `Rep` representation — design Options shape with that in mind so the two traits can share knobs

## Sequencing

1. Ship encoder primitives + `render` against the existing `Value` type. No traits, no Generic. Validates round-tripping against the parser.
2. Add the `ToJson` trait and primitive/container impls. Users can hand-write all impls. Library is now usable without compiler changes.
3. Add post-process combinators (`J.update_field`, `J.rename_field`, `J.remove_field`, `J.insert_field`, `J.map_object`). Useful in Tier 2 impls even before Generic lands.
4. When Generic lands, add `generic_to_json` and `Options`. `deriving (ToJson)` becomes available; full Tier 2 spectrum unlocked.
5. `FromJson` symmetric pass: combinators for decoder-side `refine`-style validation, `Options` shared knobs with `ToJson`.

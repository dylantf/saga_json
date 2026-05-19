# JSON Serialization — Design Notes

Status: planning. Depends on Generic landing in the compiler (see `saga/examples/99-generic-spike.saga`).

## Scope

Add encoding to `saga_json`. Currently the library only decodes (`Json -> a needs {Fail Error}`). We need the symmetric direction: `a -> Json`, plus rendering `Json -> String`.

## Library-only work

No language features are blocked. The library needs:

### Encoder primitives

Thin wrappers over the existing `Value` constructors, all returning `Json`:

```
pub fun string : String -> Json
pub fun int    : Int -> Json
pub fun float  : Float -> Json
pub fun bool   : Bool -> Json
pub fun null   : Json
pub fun array  : List Json -> Json
pub fun object : List (String, Json) -> Json
```

### Renderer

`render : Json -> String`, walks the `Value` AST.

- Numbers: `show` (Int / Float Show instances)
- Strings: byte-level escape over `BS.from_string`, mirroring `escape_byte` in `Parser.saga:55-64`
- UTF-8 passes through verbatim; escape only control chars, `"`, `\`
- Compact output first; pretty-printing later if needed

### Trait

```
trait ToJson a {
  fun to_json : a -> Json
}
```

Encoders are plain functions, no effect row. Encoding cannot fail in any honest way.

Library impls: `String`, `Int`, `Float`, `Bool`, `List a where ToJson a`, `Maybe a where ToJson a`, plus the Generic Rep building blocks (`U1`, `Leaf`, `Labeled`, `And`, `Or`).

## Generic & deriving

Once compiler-side Generic lands and is auto-derived for all types, users get `deriving (ToJson)` and a delegating impl is synthesized. The library provides ToJson impls for the Rep building blocks; the compiler-synthesized delegating impl bridges user types to those.

A second helper trait `ToJsonFields` is likely needed for the inner `And`-tree of records (a single `Labeled` produces a `(String, Json)` pair, not a complete `Json` — only `And` at the top wraps into `VObject`). GHC.Generics splits the same way (`GToJSON` for values vs. fields).

## The user-facing ladder

There are **two tiers**. Inside the manual tier, `generic_to_json` is one helper among others.

### Tier 1: Derive

```
record User { ... } deriving (ToJson)
```

Compiler synthesizes the impl using the canonical defaults (see below). Zero ceremony.

### Tier 2: Manual impl

```
impl ToJson for User {
  to_json u = <anything : Json>
}
```

The body is a spectrum:

- `generic_to_json default_options u` — equivalent to Tier 1
- `generic_to_json (Options { rename_all: CamelCase }) u` — derived shape with uniform tweaks
- `generic_to_json options u |> <post-process combinators>` — derived shape with targeted shape edits
- `J.object [("name", J.string u.name), ...]` — hand-built from scratch
- Any mix

Tier 2 is one tier with a spectrum, not separate options.

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

If a type has both `deriving (ToJson)` and a hand-written `impl ToJson for Foo`, **compile error pointing at both sites**. Don't silently pick a winner. Matches Rust's behavior with `#[derive(Serialize)]`.

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

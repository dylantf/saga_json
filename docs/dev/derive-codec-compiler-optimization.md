# Closing the derived-codec gap: notes for the compiler team

Internal working notes. Goal: get `deriving (ToJson, FromJson)` to hand-written
speed. This documents what the library now does, where the remaining gap is,
and — backed by measurements — exactly which compiler transforms close it.

The headline finding: **encode and decode have *different* dominant residues, so
they need *different* folds.** Don't apply the encode lever to decode; the
measurement below shows it buys ~nothing there.

## Current state (100k records, median ms)

| variant          | fields | encode (derived / hand) | decode (derived / hand) |
| ---------------- | -----: | ----------------------: | ----------------------: |
| standard         |      7 |          215 / 118 (1.8×) |          260 / 234 (1.1×) |
| wide             |     30 |          539 / 269 (2.0×) |         1419 / 728 (1.95×) |

Decode used to be ~2.1× (standard) before the streaming change landed
(commit `210935d`); it is now ~1.1× on the standard payload. The wide payload
barely moved on wall-clock but allocates far less (better GC profile). Encode is
untouched by that change.

Benchmark sources: `json_bench/saga/src/CodecPath*.saga` (hand) vs
`CodecPath*Derived.saga` (derived); wide = `*Wide*`. The bench path-deps the
working copy of this repo, so library edits are picked up directly.

## Architecture recap (what the derive emits, what the library provides)

`deriving (ToJson)` / `(FromJson)` emits a `Generic a r` instance (`to : a -> r`,
`from : r -> a`) where `r` is the structural rep built from `Std.Generic`:
`Adt`, `Record`, `Variant n`, `And`, `Or`, `Labeled n`, `Leaf`, `U1`. A record
`User { id, name, … }` → `Record (And (Labeled "id" Int) (And (Labeled "name" String) …))`.
The user type's `ToJson`/`FromJson` impl routes through `to`/`from` and the
library's impls on the rep pieces. No JSON-specific code is in the compiler.

The rep is already deforested in Core (confirmed earlier). What survives is
**per-field residue**, and it differs by direction.

## Encode: residue is per-field key derivation

`ToJsonFields`/`Labeled` ([lib/Codec.saga](../../lib/Codec.saga)) computes, per
field per record:

```
apply_name_style opts.rename_all (symbol_name (Proxy : Proxy n))
```

then emits `[(name, to_json opts x)]`, which `object` frames with `{`, `"`,
`:`, `,`. The hand impl instead emits `raw "\"id\":"` — a baked literal — and
recurses `to_json opts u.id`. So the encode gap is the key derivation plus the
`(String, Iodata)` list framing that the literal-concatenation hand impl skips.

Earlier Core analysis on encode attributed ~1.4M allocations/run to the
`symbol_name (Proxy n)` proxy closures + `Proxy` allocs + the per-field
`apply_name_style` calls. That is the encode lever.

### Encode levers (in order)

1. **β-reduce `symbol_name (Proxy : Proxy n)` to the literal field name.** `n`
   is a statically-known `Symbol` at the derive site. This removes the proxy
   closure + `Proxy` alloc and produces a literal-key candidate.
2. **Fold `apply_name_style style literal`.** This is gated on binding time
   (below). If it folds, the encoder emits `raw "\"id\":"` literals = hand.
3. **Fuse the `(String, Iodata)` field-list + `object` framing** so the encoder
   `concat`s literal punctuation directly instead of building a list of pairs
   and walking it.

## Decode: residue is rep-wrapper allocation + Generic `from` (NOT key folding)

After commit `210935d`, decode takes a single-param streaming fast path
(`FromJsonStream`): read key → match this field's name → parse the value in
place → return the tail; `And` does left, consume `,`, right. Same algorithm as
the hand decoder. `FromJson for Record` falls back to the old assoc-list path
only on key-order deviation / extra keys.

**Measured disaggregation (wide decode, 30 fields):** temporarily stripping the
per-field key derivation entirely (skip `apply_name_style` + `symbol_name` + the
name compare, trust order) moved wide decode **1419 → 1363 ms (~4%)**. So the
encode lever (#1/#2 above) is **nearly irrelevant for decode.** The ~635 ms that
remains over hand (1363 vs 728) is:

- **rep-wrapper allocation:** the fast path builds `Labeled v`, `And lv rv`,
  `Record "" _` boxes (30 fields → ~59 wrapper allocs/record × 100k = ~6M
  allocs) that `from` immediately tears down to construct the real record.
- **Generic `from` traversal:** walking that 30-deep `And` spine per record.

The hand decoder builds the target record directly from the byte stream — no
intermediate rep. This is also what drives the GC pressure on wide.

### Decode lever (the one that matters)

3. **Inline/fuse Generic `from` (and `to`) through the rep wrappers** so
   `from (Record "" (And (Labeled v1) (And (Labeled v2) …)))` becomes direct
   record construction and the `Labeled`/`And`/`Record` boxes never materialize.
   This is the decode lever *and* the GC lever. Steps 1/2 are optional polish
   for decode (worth ~4% on wide); do them for encode, not for decode.

## The binding-time wall (affects encode step 2)

`apply_name_style style literal` can only fold to a literal key if `style` is
known at compile time. Today `rename_all` is a runtime `Options` field, so for
`serialize_with opts x` the renamed key can *never* fold — information-
theoretically, there's nothing to specialize against until runtime. Two ways
out:

- **(a) serde model — make naming a derive-time decision** (an attribute / a
  statically-known parameter), so `apply_name_style` folds away and encode emits
  literal keys. Biggest win, biggest surface change.
- **(b) const-fold the default only:** recognize `apply_name_style AsIs x = x`
  and fold it when `rename_all` is statically the default. Covers the common
  no-rename case while keeping `rename_all` a runtime knob for the rest. Cheap,
  partial.

This wall is encode-specific. Decode does not need it (step 3 is the decode
lever, and it's binding-time-independent).

## Surface-syntax limitation found (relevant if you'd rather the *derive* emit it)

A fully order-tolerant *streaming* decoder (matching the hand impl's arbitrary-
key-order single pass, no fallback) needs a typed per-field **builder**: a
parallel tree of `Maybe`-slots (`Maybe a` for a field, `And bl br` for a
product). That requires a fundep trait `FromJsonBuilder rep b` (rep determines
b). It **cannot be hand-written as library impls** today, because:

- The `impl` parser only accepts a bare ident (nullary type or type variable)
  for trait args before `for` (`src/parser/decl.rs` ~L1006). A compound second
  arg like `(Maybe a)` / `(And bl br)` is unparseable.
- Omitting it → "expects 1 type argument, 0 provided" (the determined param is
  not inferred from the body).
- A bare var → the instance is under-determined (`FromJsonBuilder mb (Labeled n a)`
  for any `mb`), so use sites get "ambiguous type variable." The fundep is not
  used to pin a compound determined param.

So the library settled for the in-order-fast-path + assoc-list-fallback design
(single-param `FromJsonStream`, which *is* expressible). If you want the
faithful builder decoder instead, it has to be **emitted by the derive macro**
(AST-level, bypassing the parser), or the compiler needs: (1) compound trait
type-args in `impl` heads, and (2) fundep-based determination of them. That is
the "walk the rep we build and emit direct code" path — and note step 3 above
(fuse `from`) gets most of the same win without it.

## How to verify

- Build/run `json_bench/saga` with the bin pointed at `CodecPath*Derived.saga`
  vs `CodecPath*.saga`. Encode and decode are timed in separate loops (separate
  live heaps) — keep it that way; mixing them reintroduces the GC artifact noted
  in `codec-consolidation.md`.
- **Disaggregation method** (used above): to measure how much of a residue a
  fold would buy, stub it out in the library and re-run. E.g. to confirm a
  decode fold target, skip the work in `FromJsonStream`/`Labeled` and compare.
  Keep the `record_fallback` panic trick (crash on fallback) in during such runs
  so a silent fallback can't mask the result.
- Correctness is guarded by `tests/FromJsonTest.saga` ("key order (fast path +
  fallback)" block): in-order → fast path, out-of-order / extra key / nested
  reorder → fallback, all round-trip.

## Summary

| direction | dominant residue | lever | binding-time dep |
| --------- | ---------------- | ----- | ---------------- |
| encode    | per-field key derivation + field-list framing | β-reduce `symbol_name (Proxy n)`; fold `apply_name_style`; fuse `object` framing | yes (rename_all must be static to bake literal keys) |
| decode    | rep-wrapper allocs + Generic `from` traversal | inline/fuse `from`/`to` through `Labeled`/`And`/`Record` | no |

All of these are now **local** transforms (β-reduction, constant folding,
inlining) — the algorithmic restructuring is already done in the library. That
is the point of the streaming spike: it turned an intractable supercompilation
problem (fuse an assoc-list producer with a by-name-lookup consumer, invert the
control flow) into ordinary partial evaluation.

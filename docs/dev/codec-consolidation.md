# Codec consolidation & decode-perf investigation (handoff notes)

Internal working notes — not user-facing docs. Written to survive a context
compaction so the state and the open investigation can be picked back up.

## TL;DR

- Performance work on the JSON library is "good enough for now"; Saga beats
  Elixir/Gleam/Python and is within range of C#.
- We consolidated the fast path into one module, **`SagaJson.Codec`**, and
  deleted the experimental `Fast` / `FastIo` / `Stream` modules.
- **Encode is great**: 325 ms / 100k × 30-field records (better than the old
  FastIo 387 ms).
- **Decode regression is RESOLVED — it was a benchmark artifact, NOT a real
  regression** (see the "RESOLVED" section below). There is **no cross-module
  call penalty**. The apparent 2.7× (2092 ms cross-module vs 738 ms local) came
  from the two benchmark drivers having different live-heap/GC state: the
  cross-module driver kept the 100k-record `rows` list live (and ran an encode
  loop) through decode; the local driver let `rows` die first. Removing the
  encode loop from the cross-module bench → decode drops to **764 ms** ≈ the
  local 738 ms, decoder untouched. `SagaJson.Codec` can stay the shared home for
  fast-path primitives; the `deriving` codegen can call into it freely.

## How we got here (perf journey, for context)

Two encode/decode "tracks" exist by design:

- **Flexible track** (`SagaJson.Encode` / `SagaJson.Decode`): `Value`/`Json`
  AST, Generic-derived `ToJson`/`FromJson`, full `Options`, combinators
  (`field`/`at`/`list_of`), post-processing (`update_field`/`map_object`/…),
  dynamic JSON. This is the stable, flexible path and the current `deriving`
  target. **Unchanged** by this work.
- **Fast track** (now `SagaJson.Codec`): encode straight to iodata, decode
  straight from bytes into the target type — no `Value` AST on either side.
  Throughput path and the eventual codegen target.

Key perf wins landed earlier (all kept):

1. `BS.concat` (= `iolist_to_binary`) and `BS.to_string_unchecked` added to the
   stdlib (in the saga compiler repo: `src/stdlib/BitString.{saga,bridge.erl}`).
   **Compiler was rebuilt** (`cargo build` in `/home/dylan/projects/saga`).
2. Escapers rewritten to **scan-and-slice** with a binary match context
   (zero-copy clean runs, fast path for no-escape strings). Shared in
   `SagaJson.Escape` (internal). The earlier per-byte `acc <> <<c>>` append was
   the big encode bottleneck — fixing the *traversal* (match context, not
   `binary:at`) gave a 3.3× encode win (440→135 ms on the narrow workload).
3. Parser string + number parsing rewritten scan-and-slice; `Int.parse` bridge
   switched from `string:to_integer` to `binary_to_integer` (in the compiler
   repo: `src/stdlib/Int.bridge.erl`, compiler rebuilt). These cut the
   Value-path decode meaningfully.
4. The `Value` AST is the irreducible cost on the flexible decode path;
   skipping it (fused decode) is the only way past it — hence `Codec`.

The "fused decode" spike that motivated `Codec`:

- `FusedPath.saga` (positional, in-declaration-order): **608 ms**.
- `FusedArbitrary.saga` (arbitrary key order via a `Maybe`-slots builder):
  **771–778 ms** — beats Jason's 857 ms while producing a typed record.
- Both used the (now-deleted) `SagaJson.Stream` primitives.

Cross-language comparison the user assembled (100k records, median ms):

Simple (small record):

| Language | Deserialize | Serialize | Roundtrip |
| -------- | ----------: | --------: | --------: |
| C#       |          79 |        38 |       116 |
| Elixir   |         285 |       597 |       882 |
| Gleam    |         232 |        93 |       325 |
| Python   |         336 |       277 |       612 |
| Saga     |         226 |       133 |       435 |

Wide (30 fields):

| Language | Deserialize | Serialize | Roundtrip |
| -------- | ----------: | --------: | --------: |
| C#       |         129 |        49 |       177 |
| Elixir   |         857 |       895 |      1752 |
| Saga     |     771 (fused) | 387 (fastio) |   1159 |

## Design decisions settled

- **Options**: read once from the `JsonOptions` effect at the
  `serialize`/`deserialize` entry point, then **threaded explicitly** as an
  `Options` value through `to_json` / `from_json`. The trait signatures are
  `to_json : Options -> a -> Iodata` and
  `from_json : Options -> BitString -> Result (a, BitString) Error`.
  Per-node code never touches the effect. Default options are the fast lane;
  active `rename_all` costs a per-field `apply_name_style` (same cost the
  flexible path already pays). Static options are constant-foldable by a future
  compiler pass; dynamic options compute at runtime, cheaply.
- **Specialization is "not magic"**: the hand-written `Codec` impls (in the
  benchmark) are a faithful proxy for what the deriving codegen will emit —
  the compiler walks the Generic `Rep` at compile time and emits the flat
  function, skipping the runtime `Rep` traversal + dispatch. The proxy assumes
  statically-known options.
- **Keep `Value`**: dropping it would lose dynamic decoding, the
  `field`/`at`/`list_of` combinator API, and `Json↔Json` transforms — none of
  which are "options". Internally-tagged / untagged sums need a buffer (serde's
  `Content` move). So `Codec` is additive; the flexible path stays.
- **Call site stays canonical**: users call `serialize` / `deserialize` /
  `ToJson` / `FromJson`. Whether the fast or flexible path runs is determined
  by the target type's decoder (derived = fast once codegen lands; hand-written
  / dynamic = flexible). Module named `Codec` for now — rename freely.

## What changed in this consolidation pass

In `saga_json/`:

- **Added** `lib/Codec.saga` (`SagaJson.Codec`): `Iodata` type;
  `ToJson`/`FromJson` traits (options-threaded as above); primitive + `List` +
  `Maybe` impls; `serialize`/`serialize_with`/`to_string`;
  `deserialize`/`deserialize_with`; streaming primitives `skip_ws`, `expect`,
  `parse_string`, `parse_int`, `parse_float`, `parse_bool` (these are `pub`
  because generated record/variant decoders call them); the iodata escaper.
- **Deleted** `lib/Fast.saga`, `lib/FastIo.saga`, `lib/Stream.saga` (superseded:
  Fast's string-concat encode < iodata; Fast's Value-based decode < fused).
- **Deleted** `tests/FastTest.saga`, `tests/FastIoTest.saga`; **added**
  `tests/CodecTest.saga` (ported the thorough escape edge cases — control char
  ``, multibyte passthrough, consecutive escapes — so coverage isn't
  lost).
- `project.toml` `expose` now:
  `["SagaJson", "SagaJson.Encode", "SagaJson.Decode", "SagaJson.Codec", "SagaJson.Parser"]`.
- Full suite: **239 pass, 0 fail.**

In `json_bench/saga/` (separate project, path-deps `saga_json`):

- `src/CodecPath.saga` — the migrated benchmark (30-field `Wide`, hand-written
  `ToJson` + builder `FromJson` via `Codec`). Encode and decode timed in
  **separate loops**. `project.toml` `main` points here.
- Stale/broken files that imported the deleted modules still exist but are not
  compiled unless set as `main`: `FastPath`, `FastPathWide`, `IodataPath`,
  `FusedPath`, `FusedArbitrary` (I partially edited `FusedArbitrary` trying to
  re-measure; it does **not** currently compile — it references the removed
  `SagaJson.Fast` / a `deriving (Generic, ToJson)` that needs more imports),
  `ProfDecode`. These can be deleted later.

## RESOLVED: there is NO cross-module penalty — it was a benchmark artifact (GC)

**My earlier "cross-module call overhead" conclusion was WRONG.** A compiler
agent re-investigated and found there is no per-call cross-module penalty;
cross-module and local decoders run at the same speed under identical heap
conditions. The ~2.7× gap came entirely from an asymmetry between the two
benchmark *drivers*, not the decoders.

### What actually happened

`CodecPath.saga` (cross-module) ran a warmup + 5× `encode_all` **timing loop
before** the decode loop; `LocalDecode.saga` (intra-module) had no encode loop —
it built the input once and went straight to decode. Two consequences, same
root cause (decode time tracks **live-heap / GC pressure**, which has nothing to
do with where the callee lives):

- The encode loop drives the process heap to a high high-water mark before
  decode is timed.
- More decisively: because `CodecPath`'s encode loop references `rows`, the
  100k-record `rows` list stays **live** through the decode loop. In
  `LocalDecode`, `rows` is dead after `build_strings`, so it's collected and
  decode runs against a much smaller live heap.

### The proof (verified against the original CodecPath, decoder untouched)

Edited only `CodecPath`'s `main` to remove the encode loop (so `rows` dies
before decode), leaving the cross-module `C.parse_*` decoder exactly as is:

| Condition (same cross-module decoder)              | Median decode |
| -------------------------------------------------- | ------------: |
| decode after warmup+5× encode loop (orig)          |     ~2092 ms  |
| decode timed *first*, but encode loop still present |     ~2009 ms  |
| encode loop **removed** → `rows` dead before decode |      **764 ms** |

764 ms ≈ `LocalDecode`'s 738 ms. **Same cross-module calls, gap gone.** The
agent independently confirmed the same with a single-program harness running a
cross-module and a byte-identical local decoder over the same input under the
same harness (cross ≈ local every run) and with `CodecDirect` minus the encode
loop (~750 ms).

### Why my Experiments 1–3 misled me

- **Exp. 1/2** compared two drivers with different live-heap state — apples to
  oranges. The "constant gap under 20× longer strings" was just both drivers
  being equally heap-pressured; it never isolated a per-call cost.
- **Exp. 3 (pure Erlang) was actually correct** — it measured ~1.0× and was
  *telling the truth*: cross-module calls are free in OTP. When Saga appeared to
  disagree, the right inference was "my Saga benchmark is confounded," not "the
  Saga compiler is special." The Erlang controls in
  `json_bench/saga/erl_control/` remain valid and now agree with the resolution.

### Lessons for benchmarking on the BEAM

- **Hold heap state constant** across the variants you compare: same warmup, same
  prior allocation, and the same set of values kept live. A value referenced
  later in `main` stays live the whole time and inflates intervening GC.
- When a trusted minimal control (here, hand-written Erlang) contradicts a
  bigger benchmark, suspect the benchmark first.

### Compiler takeaway

No cross-module codegen change is warranted by this. (The separate record-update
lowering fix the agent noted — `element/2` → `get_tuple_element` — is an
independent, legitimate micro-optimization, unrelated to module boundaries.)
`SagaJson.Codec` can stay the shared home for the fast-path primitives; the
planned `deriving` codegen can call into it without a locality penalty.

Encode was never affected (325 ms throughout) — consistent, since the issue was
never about calls at all.

## (historical) The open problem: Codec decode is 2189 ms (expected ~778)

Same workload (100k × 30-field `Wide`), byte-identical builder decode logic to
`FusedArbitrary` (which measured 771–778 ms). Now via `Codec`: **2189 ms**.
Encode is fine (325 ms). What was ruled out:

- **Not the entry wrapper.** Decoding via `decode_wide` directly (bypassing the
  `FromJson` trait dispatch and the per-call `with json_defaults` effect
  handler) is also ~2150 ms.
- **Not GC interleave.** Encode and decode are timed in separate loops; decode
  alone is still ~2189 ms (initial version that interleaved encode+decode per
  iter was also ~2229, so interleave wasn't it).
- **Not the primitives (per micro-bench).** 3M iterations on a fixed sample:
  - `C.parse_string` 1160 ms vs a same-module local copy 996 ms (~16%).
  - `C.parse_int` 961 ms vs a same-module local `take_int` 728 ms (~32%;
    `Codec.parse_int` uses `take_number` with float detection, the old
    `Stream.parse_int` used a simpler `take_int`).
  - Together these explain maybe ~200 ms, not the ~1400 ms gap.
- **Not a globally slower machine.** Encode got *faster* (325 vs 387).

So: identical decode source, near-identical primitives (~20% per micro-bench),
yet 2.8× slower end-to-end. The only structural change is that the primitives
moved from the small `Stream` module into the large `Codec` module, and the
decoder now calls `C.*` instead of `Stream.*`. The compiler was **not** rebuilt
between the 778 and 2189 measurements.

### Leading hypotheses (unverified) — SUPERSEDED, see "RESOLVED" section above

1. **Compiler-side: large module vs small module changes codegen** for the
   decode functions or the `case key { 30 string arms }` dispatch or the
   record-update `{ b | fk: Just v }` — something that the micro-bench (which
   only exercises one primitive in isolation) doesn't capture. The user knows
   the compiler internals and flagged this as plausible.
2. The micro-bench re-parses one fixed binary; the real decode threads fresh
   sub-binary tails through 100k different inputs. Some per-call cost (sub-binary
   creation / refc binary handling) might only manifest with fresh binaries —
   but `FusedArbitrary` did the same, so this would still have to interact with
   the module-layout change.

### Next step (recommended)

Profile the `Codec` decode with **`fprof`** to localize the 2189 ms — same
method used earlier in this project:

- Build a small-N (e.g. 3000 records) decode-only target (`module Main`,
  `main () = { build → pre-encode → decode_all → print }` with `console`).
- `saga build` it, then from `erl`:
  ```
  erl -noshell -pa _build/dev -pa _build/.stdlib/<hash> \
    -eval "fprof:apply(main, main, [unit]), fprof:profile(), \
      fprof:analyse([{dest,\"/tmp/fprof.txt\"},{sort,own}]), init:stop()"
  ```
  (entry is `'main':main(unit)`; find the current stdlib hash dir under
  `_build/.stdlib/`).
- **Delete `fprof.trace` afterward — it is multiple GB.**
- Rank functions by own-time (`grep` the analysis). Compare against the earlier
  profile where the decode buckets were: field lookup, string parse, number
  parse, object structure. The new profile should reveal whatever is eating the
  extra ~1400 ms.

### Diagnostic scaffolding currently in the bench

`CodecPath.saga` is the clean separated-loops version (no diagnostics). The
micro-bench helpers (`l_parse_string`, `l_parse_int`, `loop_codec*`,
`loop_local*`, `decode_all_direct`) were in an earlier revision and have been
regenerated away — if needed for re-measurement, they were:
`loop_codec n bs` calling `C.parse_string bs` n times vs `loop_local` calling a
same-module copy; timed with `monotonic_ms`.

## Quick reference: file locations

- Library: `/home/dylan/projects/saga_json/lib/` — `Codec.saga`, `Encode.saga`,
  `Decode.saga`, `Parser.saga`, `Escape.saga`, `SagaJson.saga`.
- Tests: `/home/dylan/projects/saga_json/tests/` — run with `saga test`.
- Benchmark: `/home/dylan/projects/json_bench/saga/` (path-deps `saga_json`);
  `main` in its `project.toml` selects which bench; run with `saga run`.
- Compiler + stdlib: `/home/dylan/projects/saga/` — stdlib in `src/stdlib/`;
  `.saga` and `.bridge.erl` are `include_str!`-embedded, so **rebuild with
  `cargo build`** after stdlib edits. `~/.saga/bin/saga` symlinks the debug
  build.
- Saga gotchas hit this session: `after` is a reserved word (use another name);
  `case <expr> : Type { … }` needs parens around the ascription;
  `expr with <handler-application>` at fun-body level needs the handler
  `let`-bound first; trailing commas OK; `do { Ok x <- … } else { Err e -> Err e }`
  for Result; binary patterns `<<34, rest/binary>>`, `<<c:8, _>> when c < 32`.

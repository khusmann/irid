# Protocol Types — First-Principles Reorganization (proposal)

Status: **design complete — ready to implement; no open questions.** Start at §10
(commit plan + orientation). Run `dev/spikes/protocol-serialization.R` first to
internalize the serialization contract.

Scope: the typed wire contract in [`srcts/src/protocol.ts`](../srcts/src/protocol.ts)
— the single shape definition the R server (and a future Python server) target and
the client implements. Goal: make the shapes **easier to reason about**, which here
means three concrete things — name each concept once, make illegal states
unrepresentable, and stop overloading `id`. The wire format is allowed to change
(R is greenfield; the e2e suite is the safety net).

---

## 1. What's wrong with the current organization

The file is a single flat list of interfaces. The problems, from most to least
impactful:

1. **One concept, several encodings.** The optimistic-update echo gate appears
   three ways: flat `sequence?` + `channel?` on `IridAttrDomMessage` and
   `IridAttrTextMessage`, and a nested `EchoGate {seq, channel}` map
   (`value_meta`) on the widget variant. `sequence` vs `seq` is the same number
   under two names. `isStaleEcho` takes loose positional `(seq, channel)` because
   there is no single gate object to pass.

2. **Correlated fields encoded as independent optionals → illegal states.**
   `IridEventEntry` is flat, so the type permits `{ mode: "throttle" }` with no
   `ms`, `{ source: "widget", preventDefault: true }` (a widget channel attaches
   no DOM listener — the flag is inert), and `kind` carries a phantom `| null`
   that the wire never sends (R omits the key; the client only reads `kind` on the
   widget branch). The discriminant that governs each cluster — `mode` for timing,
   `source` for `kind` vs DOM flags — is present but not used to discriminate.

3. **`id` means three different things.** Across messages `id` is variously a DOM
   element id (`getElementById`), a comment-anchor-pair id, or an output name
   (`irid-ready`). The reader has to know which per message. The channel string is
   itself named two ways — `inputId` on the event entry, `channel` on the gate —
   for one value.

4. **Two audiences in one file.** The server↔client **wire** types and the public
   **widget-author API** (`WidgetFactory`, `WidgetHandle`, `SendEvent`/`SetProp`,
   the `window.irid` / `irid:ready` globals) have different stability contracts and
   different readers, but sit interleaved.

5. **Wire-shape discipline is scattered across send sites.** Array fields are kept
   array-safe ad-hoc — `as.list(removes)` / `as.list(vapply(…, USE.NAMES = FALSE))` at
   [mount.R:195-208](../R/mount.R#L195-L208) (with a 4-line comment on the
   named-vector→JSON-object trap) — and the non-empty `value_meta` guard sits inline at
   [mount.R:74](../R/mount.R#L74). The wire is clean *by scattered discipline* — every
   author must remember the `as.list`/`USE.NAMES`/guard tricks. That belongs in one
   encoder (§9). (The `__irid_state_keys` `string | string[]` over-wide type was a
   third instance, now moot — the field is deleted via NULL-prop preservation, §11.)

---

## 2. First-principles model

Three axes organize everything:

- **Audience/stability.** The internal wire contract (both directions — messages and
  payloads) vs the public widget-author API (a DOM/JS contract). These are the two
  modules; direction is an in-file *section*, not a file (§7).
- **Shared vocabulary.** A handful of value types recur across messages —
  `EchoGate`, `DomOpts`, `Timing`, `EventKind`. Name each once, reuse everywhere.
  This is what collapses "one concept, several encodings." All wire-only, so they
  live in `wire.ts` (§3) alongside the messages — there is no separate vocabulary
  file (see §7 for why `common.ts` was dropped).
- **Identity.** Every `id`/channel string resolves against *something*. Give each
  referent a named alias so the type says what the string points at (also wire-only,
  in `wire.ts`).
- **Default ownership.** Defaults are resolved by the **producer** (R, and the
  future Python server) into *total* values on the wire; consumers never re-derive
  them. It follows that **optionality marks semantic absence only — never
  default-elision.** A field is optional iff its absence is **contextual** — the
  field doesn't apply here (no client write → no `gate`; app isn't an output → no
  `output`; a variant lacks the field → `ms` only under throttle/debounce). A field
  whose "absence" would merely re-encode its default is **required, with that default
  explicit** — `false` for booleans (`preventDefault`, `coalesce`, `clientOnly`,
  throttle `leading`, `staleTimeout`), and `null` for an optional-string member of a
  materialized record (`DomOpts.filter` — `null` is its `false`). R already sends
  these concretely, so the client drops its defensive `!!`/coercion reads. Rationale:
  with two servers and one client, a default belongs in the producers, resolved
  once, not re-implemented per consumer ("parse, don't validate" at the boundary).
  The split: **contextual absence omits; a record field carries its off-default
  (`false`/`null`).**
- **Naming.** Wire envelope fields are **camelCase**. Verified across the complete
  field set (every `msg.<field>` the client reads + every R sender key): the lone
  offender today is `value_meta`, fixed to `valueGates` by this redesign — after
  which the envelope is uniformly camelCase. Two non-camelCase categories are
  *deliberate, not violations*: (1) the `__irid_*` prefixed fields existed only to
  smuggle metadata into a foreign-keyed bag — **both are being deleted**, `__irid_seq`
  by the §5 payload envelope and `__irid_state_keys` by NULL-prop preservation (§11),
  so the prefix convention leaves the protocol entirely; (2) keys *inside*
  `values`/`props` (`xaxis_range`, `dragmode`, …) — these are the **widget's** own
  vocabulary (plotly's), not irid's protocol, so their casing is the widget author's
  call. The rule governs the protocol envelope, not payload data it carries.

Composition over inheritance throughout: arms share a core by intersection (`&`),
and cohesive field clusters (`DomOpts`, `Timing`) are **nested members**, not
flattened in.

---

## 3. The wire contract (`protocol/wire.ts`)

Both directions, and the vocabulary they're built from, live in one file (§7) — here
split into: the vocabulary, the server→client messages, then the client→server
payloads (§5). **There is no `common.ts`:** every value-type *and* every id alias is
wire-only. `widget.ts`'s one potential cross-reference — the `irid:ready` detail —
uses plain `string` (§6), so nothing is shared and the only files are `wire.ts` +
`widget.ts` (see §7).

### Vocabulary

The id aliases plus the value-types every message is built from.

```ts
// Identity aliases (documentation-only; all `string`; not branded — see §11).
// Each names what the string resolves against.
export type ElementId = string;   // resolves via document.getElementById
export type AnchorId  = string;   // a comment-anchor-pair id (range protocol)
export type OutputName = string;  // a Shiny output id (renderIrid / iridOutput)
export type Channel   = string;   // a Shiny input id; also the per-channel seq key
```

```ts
// --- Optimistic-update echo gate -------------------------------------------
// The single representation everywhere a gate travels. Carried as `gate?: EchoGate`
// (omitted/undefined for a programmatic write), NOT `EchoGate | null` and NOT a
// tagged union. A gate is a *relationship* (a client send ↔ its echo), so its absence
// is CONTEXTUAL — a programmatic write has no client channel, so there's no gate, vs
// `DomOpts.filter` whose null IS a materialized off-default value. `gate: null` would
// be incoherent ("a gate that is null") and would split how "programmatic" is encoded:
// the SAME concept on the widget side (valueGates) is a sparse map that *omits*
// programmatic keys, so the dom gate omits too — one encoding for "no gate". (Also:
// programmatic is the common path; null'ing every such message is verbose for nothing.)
export interface EchoGate {
  seq: number;
  channel: Channel;       // same-file alias (see Vocabulary above)
}

// --- DOM listener options --------------------------------------------------
// Mirrors R's `wire_dom_opts(prevent_default, stop_propagation, capture, passive,
// filter)` 1:1 (event.R:119). DOM-only; a widget channel has no listener. This is a
// fully-MATERIALIZED config record: every field is present, carrying its type's "off"
// default — `false` for the flags, `null` for `filter`. None is omitted (a field here
// is a config setting, not a contextual artifact like `gate`). So `domOpts` itself is
// required too: an absent DomOpts would just re-encode {4 false, filter null}.
export interface DomOpts {
  preventDefault: boolean;
  stopPropagation: boolean;
  capture: boolean;
  passive: boolean;
  filter: string | null;  // JS predicate over `e`, or null for none. REQUIRED with an
                          // explicit off-default — `null` is to filter what `false` is
                          // to the flags above (every DomOpts field is present, carrying
                          // its type's "off" value). Not omitted: filter is a member of
                          // this materialized record, not a contextual field. (No "" —
                          // R forbids it, allow_empty=FALSE.) R's list() already emits
                          // `filter:null`, so the encoder does nothing special.
}

// --- Rate-limit timing -----------------------------------------------------
// Discriminated on `mode`, mirroring R's pure wire_immediate/throttle/debounce
// shapes: ms/leading exist only where the variant gives them meaning (semantic
// absence, not elision — so they're absent by variant, required within it).
//
// ARM-vs-CARRIER rule: a field lives in an arm only when its *existence/meaning*
// depends on the discriminant (ms/leading don't exist for immediate → arm). A field
// valid everywhere with the same meaning, where `mode` sets only its *default*,
// stays on the carrier. `coalesce` is the latter — server-idle backpressure means
// the same thing in every mode (immediate+coalesce is wired & useful), `mode` just
// picks its default — so it is NOT here; it is carrier-level (see EventCore).
export type Timing =
  | { mode: "immediate" }
  | { mode: "throttle"; ms: number; leading: boolean }
  | { mode: "debounce"; ms: number };

// --- Widget stream kind ----------------------------------------------------
// No `| null`: absence is carried by the field being on the widget arm only.
export type EventKind = "prop" | "event";
```

---

## 4. Server→client messages (`protocol/wire.ts`)

The Shiny message-channel name is the discriminant *between* messages; within
`irid-attr`, `target` discriminates. No synthetic `type` field is added.

(`irid-attr` discriminates on `target`, `irid-events` on `source` — *not* an
inconsistency: an attr is server→client so it names a **destination** (`target`); an
event is client→server so it names an **origin** (`source`). The names are
directional on purpose; don't unify them.)

### Lifecycle

```ts
/** `irid-config` — session options pushed at start. Extensible bag. */
export interface IridConfigMessage {
  // Materialized config field: required, `null` is its off/special value (disabled),
  // exactly like `DomOpts.filter`. R always sends it (getOption default 200).
  staleTimeout: number | null;   // ms before stale indicator; null disables
}

/** `irid-ready` — a mount is fully wired. `output` is the output name for a
 *  renderIrid/iridOutput mount, and ABSENT for a top-level iridApp mount (which has
 *  no output name). Optional, not `| null`: top-level is *semantic* absence (no name
 *  exists), one canonical encoding. NOTE: today R sends `list(id = NULL)` → the
 *  single-`list()` constructor keeps the element → `{"id":null}` on the wire (NOT
 *  absent — see §9). So this is an encoder *decision*: emit the field only when an
 *  output name exists, never `null`. The client maps absent → null only when it
 *  synthesizes the PUBLIC `irid:ready` detail (`msg.output ?? null`), where
 *  `{ id: string | null }` suits a JS consumer (§6). Wire = optional/omitted;
 *  public DOM detail = null. (Renamed from the overloaded `id`.) */
export interface IridReadyMessage {
  output?: OutputName;
}
```

### Bindings — `irid-attr` (discriminated on `target`)

```ts
export type IridAttrMessage =
  | IridAttrDom
  | IridAttrText
  | IridAttrWidget;

/** DOM property/attribute write on getElementById(id). */
export interface IridAttrDom {
  target: "dom";
  id: ElementId;
  attr: string;
  value: unknown;           // string | number | boolean | null in practice; `unknown`
                            // so the handler makes no coercion assumptions
  gate?: EchoGate;          // CONTEXTUAL absence (§2): omitted for a programmatic
                            // write (no client channel to gate against). Only dom
                            // carries it (value/checked echoes on focused inputs);
                            // text never does (see IridAttrText).
}

/** Text replacement inside a comment-anchor range. */
export interface IridAttrText {
  target: "text";
  id: AnchorId;
  // `string`, not the old `string | number | null`. `number` is dead — coerce_text_child
  // runs as.character() before send (mount.R:500), so 42 arrives as "42". The client
  // treats "" as "clear the range", so empty IS the canonical clear signal — no null
  // needed. PRODUCER FIX (§8): as.character(NULL) is character(0) → serializes as `[]`
  // today, so coerce_text_child must normalize empty/NA → "" for `value: string` to hold.
  value: string;
  // NO gate. The echo gate exists for cursor/focus preservation on a controlled
  // input being typed into; a text node is display-only — you can't type into a
  // comment-anchor range. Structurally, "text" is never an event `write_target` and
  // an anchor id is never an event source, so the seq/channel lookup is always NULL
  // for a text binding (mount.R:493) — the field is dead today. A text echo is
  // always programmatic and applies unconditionally. Gate lives only on dom +
  // widget.
}

/** Coalesced batch routed to a widget's update() hook. */
export interface IridAttrWidget {
  target: "widget";
  id: ElementId;
  values: Record<string, unknown>;        // { attr -> value }, ≥1 key. The DATA —
                                          // always present (contrast valueGates).
  valueGates?: Record<string, EchoGate>;  // was value_meta. Sparse gate ANNOTATION:
                                          // an entry only for a key from a client
                                          // write; absent key = programmatic. Omitted
                                          // (not present-empty `{}`) when no key is
                                          // gated: `{}` and undefined are semantically
                                          // identical here (both = all-programmatic),
                                          // so pick one — and omit matches the scalar
                                          // `gate` (same echo-gate concept: the gate
                                          // field is ABSENT when no gating context, at
                                          // both cardinalities). Programmatic is the
                                          // common path, so `{}` would be noise.
}
```

`isStaleEcho` becomes `(gate: EchoGate | undefined, seqs) => boolean` — one shape,
called identically from the dom path (`msg.gate`) and the widget per-key path
(`valueGates[k]`). Text carries no gate, so it never calls it.

### Structure — comment-anchor range ops

One message for *all* dynamic content. `irid-swap` is **deleted** — When/Match now
reconcile through `irid-mutate` like Each (§11: control-flow rendering is unified —
When/Match are single-slot keyed reconciliation, a flip is `{removes:[old],
inserts:[new]}`, an empty branch is `{removes:[old]}`).

```ts
/** `irid-mutate` — granular comment-anchor range mutations. The sole structural
 *  message: drives Each (N keyed/positional children) AND When/Match (one child,
 *  keyed by active branch/case). Child ids are AnchorIds. */
export interface IridMutateMessage {
  // removes/inserts/order are CONTEXTUAL command-parts, each omitted when this
  // mutation doesn't do it (an append is just `inserts`, a reorder just `order`).
  // Omit, not present-empty `[]`: unlike DomOpts (a uniform record where every field
  // always applies), a mutate is independent optional operations — "doesn't reorder"
  // → omit `order`, like "no client write" → omit `gate`.
  id: AnchorId;
  removes?: AnchorId[];
  inserts?: string[];     // HTML fragments (each its own anchored child range)
  order?: AnchorId[];
}
```

### Events — `irid-events` (array of entries; `source` union)

```ts
/** Shared core. `channel` replaces `inputId` — it is the Shiny input id the
 *  client sends on AND the per-channel sequence key (same string EchoGate.channel
 *  references). One name for one value. */
export interface IridEventCore {
  id: ElementId;
  event: string;          // the DOM/widget event NAME
  channel: Channel;
  timing: Timing;         // nested; ms/leading live inside per mode
  coalesce: boolean;      // carrier-level (orthogonal to mode — see Timing's
                          // arm-vs-carrier rule); R resolves NULL→mode default
}

/** DOM event: the listener options (incl. filter) + the config-only flag. */
export type IridDomEvent = IridEventCore & {
  source: "dom";
  domOpts: DomOpts;       // required; carries the flags AND filter (= wire_dom_opts)
  clientOnly: boolean;    // config-only wire: attach flags, never round-trip
};

/** Widget event: carries kind; no DOM flags (no listener is attached). */
export type IridWidgetEvent = IridEventCore & {
  source: "widget";
  kind: EventKind;        // required, no null — falls out of the union
};

export type IridEventEntry = IridDomEvent | IridWidgetEvent;
```

This makes the three illegal states from §1.2 unrepresentable: a `throttle` with no
`ms` won't type; `preventDefault`/`filter`/`clientOnly` don't exist on the widget
arm; `kind` is required-without-null on the widget arm and absent on the dom arm.
The handler already forks on `source` ([handlers.ts:214](../srcts/src/core/handlers.ts#L214),
[:229](../srcts/src/core/handlers.ts#L229)), so the union narrows exactly where the
code already branches. `attachListener` / `attachClientOnlyListener` /
`compileFilter` narrow their params to `IridDomEvent` (or just `DomOpts`), so they
can no longer be handed a widget entry.

### Widget init — `irid-widget-init`

```ts
export interface IridWidgetInitMessage {
  id: ElementId;
  name: string;
  props: Record<string, unknown>;   // see WidgetFactory's `props` param (§6)
}
```

---

## 5. Client→server payloads (`protocol/wire.ts`, same file as §3–4)

Every client→server payload is an **envelope wrapping the event data**, not a flat
bag with metadata mixed in:

```ts
/** What goes on the wire for every client->server payload: irid's transport
 *  envelope owning the top level, with the foreign-keyed event data under `data`
 *  (DOM event fields, or a widget author's sendEvent payload). No `nonce` — it was a
 *  Math.random() to force value-distinctness, but every payload is sent with
 *  {priority:"event"}, which bypasses Shiny's no-resend dedup (shiny.js:11187, §9),
 *  so it was vestigial. */
export interface EventPayload {
  id: ElementId;        // source element (carried explicitly — robust under
                        // Shiny-module namespacing, where the inputId is opaque)
  seq: number;          // per-channel monotonic sequence (the echo gate)
  data: Record<string, unknown>;
}
```

**Why the envelope, not flat-with-prefix.** The payload is both irid's transport
*and* the source of the user's event object. If the two share one flat namespace,
irid's bookkeeping must dodge collisions with DOM event fields *and* arbitrary
widget-author `sendEvent` keys — which is why today's wire smuggles a *prefixed*
`__irid_seq` next to an *un*prefixed `id` (an inconsistency: a widget author's
`sendEvent("x", { id })` silently clobbers the envelope's `id`). Nesting the foreign
data under `data` gives irid sole ownership of the top level, so **no prefix is
needed at all** — `seq` is just `seq`. The user handler still gets `e$value` flat:
the decoder hands it `payload$data` (§9), so the nesting is wire-only. This is the
idiomatic "envelope wraps payload" shape, and it deletes the entire `__irid_*`
convention from the client→server direction. `irid_decode_payload` becomes
`event_obj <- payload$data` — a field read, no strip-list.

(The other prefixed field, `__irid_state_keys`, is deleted a *different* way — by
fixing the NULL-prop dropping that forced it to exist, so the factory derives its
state args from the full prop set. See §11. Net: both `__irid_*` fields gone, the
prefix convention removed from the protocol.)

---

## 6. Public widget-author API (`protocol/widget.ts`)

Separated because the audience and stability contract differ from the wire: this is
what a third-party widget author writes against.

```ts
// No `WidgetProps` alias: with `__irid_state_keys` gone (§11) it was a transparent
// `Record<string, unknown>` — no constraint, no sibling to disambiguate from — so it
// failed "earn your place" (cf. the id aliases, kept because they *disambiguate*).
// The props contract lives on the factory's `props` param instead.

export type SendEvent = (event: string, payload?: unknown) => void;
export type SetProp   = (key: string, value: unknown) => void;

export interface WidgetHandle {
  update?(values: Record<string, unknown>): void;
  destroy?(): void;
}

export type WidgetFactory = (
  el: HTMLElement,
  /** All declared props, callable and constant alike. The factory sees EVERY prop it
   *  declared — including NULL-initialized reactives, which arrive as explicit `null`,
   *  not absent (§11). plotly relies on this to derive its state args from the prop set. */
  props: Record<string, unknown>,
  sendEvent: SendEvent,
  setProp: SetProp,
) => WidgetHandle | Promise<WidgetHandle>;

export interface Irid {
  defineWidget(name: string, factory: WidgetFactory): void;
}

declare global {
  interface Window {
    irid: Irid;
    __iridReady?: boolean;
  }
  interface DocumentEventMap {
    // `id` is the output name (renderIrid/iridOutput) or null (top-level iridApp).
    // Plain `string`, not `OutputName`: this is widget.ts's only would-be reference
    // to the wire vocabulary, and importing one alias across files isn't worth it
    // (and would re-introduce common.ts). Documented by the comment instead.
    "irid:ready": CustomEvent<{ id: string | null }>;
  }
}
```

---

## 7. Proposed file layout

```
srcts/src/protocol/
  wire.ts     vocabulary (id aliases + EchoGate/DomOpts/Timing/EventKind) + the
              transport contract, both directions, as labeled sections:
              `// Server → client` / `// Client → server`
  widget.ts   public widget-author API + window/document globals
  index.ts    barrel: `export * from "./wire"`, `export * from "./widget"`
```

**Two substantive files.** The boundary that earns its place is **audience/
stability** — internal wire vs public widget-author surface. There is *no*
`common.ts`: a shared-vocabulary file is justified only by a genuine cross-file
share, and there is none.

- `wire.ts` is the entire internal transport contract — vocabulary (id aliases +
  `EchoGate`/`DomOpts`/`Timing`/`EventKind`), server→client messages, and
  client→server payloads. They live together because (a) every one of these types is
  wire-exclusive, and (b) the two directions are read *jointly* on a round-trip (the
  outbound `gate` is gated against the `seq` the inbound `PayloadMeta` bumped on the
  same `channel`). Direction is kept as in-file sections, not files.
- `widget.ts` is the public, third-party-facing surface — different stability
  contract, so it's separate. It references *nothing* from `wire.ts`: its one
  would-be cross-reference (`irid:ready`'s detail) uses plain `string` (§6), so the
  files don't couple in either direction.

The history here is the rule eating its own tail: vocabulary started in a `common.ts`
"shared leaf," then the value-types proved wire-only and moved to `wire.ts`, then the
*last* alleged share (`OutputName` in `widget.ts`) turned out to be self-inflicted (I
aliased what the original typed as `string`) — so `common.ts` had nothing left to
justify it. A file earns its place by a real share; there wasn't one.

`index.ts` keeps the single import surface (`import type { … } from "../protocol"`
still works with the directory + `index.ts`). If we'd rather not split at all, the
fallback is one file with `wire`/`widget` as labeled sections; the type *shapes* are
identical either way.

---

## 8. Wire-format changes and R-side impact

These are real protocol changes, not TS-only. Each TS change pairs with an R sender
edit so the bytes match the type:

| Concept | Wire change | R site |
|---|---|---|
| Echo gate (dom only) | `sequence` + `channel` → nested `gate: {seq, channel}`; drop from text (always absent there) | [mount.R](../R/mount.R) attr senders (~:464, :509) |
| Echo gate (widget) | `value_meta` → `valueGates` (rename only) | [mount.R:74-88](../R/mount.R#L74-L88) |
| Event channel | `inputId` → `channel` (rename) | [mount.R:359](../R/mount.R#L359) |
| Timing | flat `mode/ms/leading` → nested `timing` discriminated obj | [mount.R:364-366](../R/mount.R#L364-L366) |
| DOM flags | flat 4 fields → nested `domOpts`; **omit on widget rows** | [mount.R:368-371](../R/mount.R#L368-L371) |
| `kind` | omit from DOM rows (today sent as `"kind":null` — see §9); required on widget | [mount.R:363](../R/mount.R#L363) |
| Ready id | `id` → `output` (optional; absent for `iridApp`) | [app.R:18-20](../R/app.R#L18) |
| Payload envelope | flat `{…fields, id, nonce, __irid_seq}` → `{ id, seq, data:{…fields} }`; deletes `__irid_seq` AND `nonce` (§9.8) | client `attachPayloadMeta`+`buildPayload`; `irid_decode_payload` ([mount.R:402-420](../R/mount.R#L402)) |
| Widget props | preserve NULL props (keep key as explicit `null`) → factory sees full set → **deletes `__irid_state_keys`**; drop client `.concat` ([plotly/index.ts:259](../srcts/src/widgets/plotly/index.ts#L259)) | widget-init seeding ([mount.R:326-333](../R/mount.R#L326)) |
| Control flow | delete `irid-swap`; When/Match emit `irid-mutate` (anchor bodies as child ranges) | [mount.R:556,566,820,852](../R/mount.R#L556) → mutate |
| array fields | move `as.list`/`USE.NAMES=FALSE` for `removes`/`inserts`/`order` into the encoder (no behavior change, cleanup) | [mount.R:195-208](../R/mount.R#L195-L208) |
| text value | drop `number`; normalize empty/`NA`/`character(0)` → `""` so wire is `string` | [mount.R:39-500](../R/mount.R#L39) (`coerce_text_child`) |

Note `coalesce` stays a carrier-level field, now **required**: R must resolve the
NULL→mode default *before* send so the wire value is a concrete boolean. Same for
the other default-elision fields made required above (`domOpts` + its flags,
`clientOnly`, throttle `leading`, `staleTimeout`) — the producer materializes them,
and the client drops its defensive `!!`/coercion reads (the `domOpts` `!!` at
[ratelimit.ts:158](../srcts/src/core/ratelimit.ts#L158); the `!!msg.coalesce` reads at
[ratelimit.ts:194,263,322](../srcts/src/core/ratelimit.ts#L194)). This is the
"producer owns defaults" rule from §2 applied concretely.

---

## 9. Serialization — SETTLED by spike

Spike: [`dev/spikes/protocol-serialization.R`](spikes/protocol-serialization.R),
run against the same `shiny:::toJSON` that `sendCustomMessage` uses (so the printed
JSON *is* the client-side shape — for server→client custom messages the client gets
`JSON.parse()` of it; `simplifyVector` only affects client→server inputs). **Pinned:
shiny 1.7.4, jsonlite 2.0.0.** 24/24 verdicts pass. Findings:

> **The spike is throwaway** — it settles the design now and is **deleted after
> implementation**. "Re-confirm on bump" therefore lives in the **e2e suite**, not
> here: the suite already exercises the real `toJSON` wire end-to-end (the app works
> iff the encoder emits the right shapes), and the encoder's dev-mode self-assert (below)
> backstops it in-process. The one assumption a normal e2e wouldn't exercise — Shiny's
> event-priority *non*-dedup (finding 8) — gets a **dedicated permanent e2e** (§10 step 5).

1. **Required booleans survive.** `coalesce = FALSE`, an all-false `domOpts`, and
   `clientOnly = FALSE` all reach the client as concrete scalars — `"coalesce":false`,
   `"domOpts":{"preventDefault":false,…}`. The producer-owns-defaults decision holds.
2. **Three "empty-ish" states the encoder must keep distinct** (the naive
   `list()`/jsonlite path conflates them):
   - **`null` is NOT absent.** The drop-on-NULL rule is for `x[[k]] <- NULL`
     (assignment); the event message uses a single `list(...)` constructor, which
     *keeps* NULL → jsonlite emits `"k":null`. So `kind`/`ms`/`leading`/ready-`id` are
     `"…":null` on the wire **today, not absent** — for the *contextual* ones the
     encoder must *actively omit* (they don't apply); `filter` stays `null` (it's a
     materialized off-default, see below). (Only the incrementally-assigned
     `gate`/`valueGates` are genuinely absent today.) **This is the non-obvious one:
     `list(x = NULL)` keeps the key as `null`; the encoder must drop contextual ones.**
   - **present-empty survives** — empty array → `[]`, empty map → `{}`, empty string
     → `""`, and all are distinct from an omitted key. **But `[]` vs `{}` is keyed off
     list NAMES** (unnamed empty list → `[]`, named → `{}`), so the encoder must build
     an empty *array* field as an unnamed list and an empty *map* as a named list.
   - Net rule the encoder enforces — **four** distinct encodings for "no value,"
     chosen per field by *why* it's empty:
     - **absent** (omit key) — a *contextual* field that doesn't apply here:
       `gate` (no client write), `output` (app isn't an output), `ms`/`kind` (wrong
       variant). The concept itself is absent.
     - **off-default in a materialized record** — a config field that's always
       present carrying its type's "off" value: `DomOpts` flags → `false`, `filter` →
       `null`. Here `null` *is* on the wire, and correctly so (it's `filter`'s `false`).
     - **present-empty** (`[]`/`{}`/`""`) — only when empty is a valid value of the
       type (empty array, empty text).
     So `null` appears for materialized off-defaults (`filter`), *not* for contextual
     absence (those omit). `filter` has no `""` form (R forbids it, `allow_empty=FALSE`).
3. **Nests round-trip as objects.** `gate`, `timing` (incl. immediate→`{"mode":
   "immediate"}` with no ms, throttle→`{…,"ms":100,"leading":true}`), `domOpts`, and
   the per-key `valueGates` map all serialize as JSON objects. immediate+coalesce is
   representable (`"timing":{"mode":"immediate"},"coalesce":true`). Omitting
   `valueGates` (programmatic) emits no key — the sparse-map encoding works.
4. **Empty-text confirms the §8 fix is required.** `as.character(NULL)` is
   `character(0)` → serializes as `[]`; `NA_character_` → `null`; `""` → `""`. So the
   honest current wire type is `string | null | []` — `value: string` only holds
   once R normalizes empty/`NA`/`character(0)` → `""` (the §8 row).
5. **Array-forcing is real but already handled ad-hoc.** A length-1 char vector
   unboxes to a scalar (`"xaxis_range"`); `I()` or `as.list()` forces
   `["xaxis_range"]`; length ≥2 is already an array. The send sites *already* do this
   — `as.list` for `removes`/`inserts`/`order` ([mount.R:195-208](../R/mount.R#L195-L208)).
   So this isn't a bug to fix but **scattered discipline to centralize** into the
   encoder.
6. **NULL props must keep their key** (for the `__irid_state_keys` deletion, §11).
   A NULL-valued widget prop must serialize as `"k": null`, not be dropped — built via
   `props[k] <- list(NULL)` (single-bracket keeps it), not `props[[k]] <- NULL`
   (drops it). Same constructor-vs-assignment distinction as finding 2.
7. **Empty `props` must be `{}`, not `[]`** (present-empty MAP, finding 3 live). A
   propless widget (`IridWidget(props = list())`) yields an empty R list, which
   serializes as `[]` unless built as a *named* list — and the factory expects an
   object. The encoder must emit `{}` for an empty `props` (and any map field). `data`
   in the payload is the same shape but client→server (JS `{}` is unambiguous).
8. **`nonce` is vestigial → delete it.** Every payload is sent with `{priority:
   "event"}`, and Shiny's no-resend dedup `return` is guarded by `opts.priority !==
   "event"` (installed `shiny.js:11187`, shiny 1.7.4) — so an event-priority input *always* sends, even
   with an identical payload. The `Math.random()` nonce that forced distinctness is
   redundant; it's also read nowhere (set in payload.ts, stripped at mount.R:418). The
   payload envelope is `{ id, seq, data }`. **Durable guard:** the §10-step-5 e2e (two
   identical consecutive events both reach the server) locks this and fails loudly if a
   future Shiny makes event-priority dedup — that's the real "confirm on bump", not the
   source read above (which only settles it now).

Findings 2 and 4 are the load-bearing ones (NULL-kept-as-null; empty-text → `[]`).
Finding 4 is the one genuine wire *fix* (normalize → `""`); the rest is the encoder
making "absent / present-empty / off-default / null" deliberate per field, replacing
whatever `list()`/jsonlite produces by accident.

### Predictable serialization — a producer-side encoder

We cannot make jsonlite itself strict on this path: Shiny owns the `toJSON` call in
`sendCustomMessage` (`auto_unbox = TRUE`, hardcoded), with no per-message config
hook. Pre-serializing ourselves and shipping a string would double-encode and fight
Shiny's model. So predictability is a **producer-construction** concern, not a
config knob — and the spike shows the non-determinism is narrow and enumerable:

- **array-typed fields that are contingently length-1** unbox to a scalar
  (`removes`/`inserts`/`order`) — shape depends on runtime *length*;
- **empty/sentinel values** encode by content (`NULL` dropped, `character(0)` →
  `[]`, `NA` → `null`) — shape depends on runtime *content*.

Everything else (scalars, named lists → objects) is already deterministic under
`auto_unbox = TRUE`. The strict-jsonlite idiom (`auto_unbox = FALSE` + explicit
`unbox()`) is the inverse discipline; since we can't flip the flag, we **emulate it
at construction** — make each field's wire shape a function of its *declared protocol
type*, never the runtime value.

**Centralize this in one producer-side wire encoder** — a thin `irid_*` message
constructor per message type (mirroring the protocol types in §4–5), rather than
scattering the rules across every `sendCustomMessage` site. The encoder **absorbs the
discipline that lives at the send sites today**, so callers pass semantic R values and
carry no jsonlite knowledge. The complete rule set (this is the encoder spec):

- **array fields** (`removes`/`inserts`/`order`) → unnamed list (`[]` when empty,
  `[x]` for length-1). Deletes the per-site `as.list`/`vapply(USE.NAMES = FALSE)` and
  the [mount.R:198-202](../R/mount.R#L198-L202) named-vector→object-trap comment.
- **map fields** (`props`, `values`, `valueGates`) → *named* list, so empty → `{}` not
  `[]` (§9.7). `valueGates` additionally **omits** when empty (contextual; §9.2/§2).
- **`string` fields** normalize empty/`NA`/`character(0)` → `""` (the text-value fix).
- **required default-carrying fields** present with their off-default: booleans →
  `false`/resolved (`coalesce` from mode), `filter` → `null`, `staleTimeout` → its value.
- **contextual fields** (`gate`, `output`, `kind`, variant-gated `ms`/`leading`) →
  **omit** when absent (today some are sent as `null` — §9.2 — the encoder must drop them).

Strictness then lives in one place that tracks the type definitions. It also gives a
natural **dev-mode assertion**: the encoder can re-parse its own output and check it
against the expected shape (or a JSON Schema generated from the protocol) in debug
builds — which would have caught the `character(0)` → `[]` wart automatically. This is
the R-side embodiment of the "producer emits total values" rule (§2).

### Inbound decode — the symmetric half

The encoder handles server→client. The client→server direction has a partner step
that today is **inline** in the event observer ([mount.R:402-420](../R/mount.R#L402)):
it reads `__irid_seq` off the payload and strips the flat envelope via
`setdiff(names, c("id", "nonce", "__irid_seq"))` to build the user-facing
`event_obj`. With the §5 envelope shape (`{ id, seq, data }`) this collapses to
**`irid_decode_payload(payload)` returning `list(meta = payload[c("id","seq")],
event = payload$data)`** — a field read, no strip-list to keep in sync, no
`__irid_*` names. Promote it to that named function — the explicit mirror of
`attachPayloadMeta` on the client. Two reasons beyond symmetry:

- **One home for the envelope.** `attachPayloadMeta` (client) wraps `{ id, seq, data }`;
  `irid_decode_payload` (R) unwraps it. The envelope shape lives in exactly those two
  mirror functions, not as inline string literals in the observer.
- **It clarifies what is NOT in this layer.** `irid_decode_payload` handles only the
  **structural envelope** (extract meta, expose the rest as fields). It does **not**
  do value coercion — turning `list(40, 200)` back into a numeric range, `NA` back
  into `NULL` — because that is *semantic* and field-specific (a date-axis range
  stays character), so it stays **per-widget** (`coerce_plotly_value`,
  `coerce_state_prop`). This asymmetry is correct: outbound, the producer totalizes
  values because it knows their types; inbound, only the consumer knows what a field
  should coerce *to*.

So the full codec is: **`irid_encode_*` (outbound, structural + value-total) +
`irid_decode_payload` (inbound, structural envelope only)**, with value coercion
explicitly scoped to widgets. The client does no runtime validation by design
(type-only TS, zod rejected — §11); well-formedness is producer-guaranteed by the
encoder, backstopped by e2e and TS compile-time types.

---

## 10. Commit plan (one concept per commit, feature branch)

**Orientation for a fresh implementer.** Read §2 (the encoding rules every field
decision follows), §8 (every R sender site that changes), §9 (the serialization
behaviors + the encoder spec). **Run `dev/spikes/protocol-serialization.R` first** —
its 24 checks *are* the serialization contract (NULL-kept-as-null, `[]`-vs-`{}` by
names, present-empty, nonce-redundant). Touchpoints: client = `srcts/src/protocol.ts`
(types — currently one file; the directory split is step 7) + `core/{handlers,
ratelimit,payload,seq}.ts` + `widgets/plotly/index.ts`; R = `mount.R`, `app.R`,
`plotly.R`. The **encoder/decoder (§9)** is the linchpin — every R-touching step
routes its sends through it, so build it in step 2 and grow it. Each step keeps the
**e2e suite green** (`TESTING.md`); that's the proof the wire still round-trips.

1. Introduce the vocabulary in `protocol.ts`, no consumers yet: id aliases +
   `EchoGate`, `DomOpts`, `Timing`, `EventKind`. (TS-only; nothing references them.)
2. `EchoGate` everywhere + stand up the **codec**: `gate?` on dom, `valueGates` on
   widget; `isStaleEcho` takes a gate; extract `irid_encode_*` / `irid_decode_payload`
   (§9) and route the attr senders through them. (TS + R + handler together.)
3. `irid-events` union: `IridEventCore` + `IridDomEvent | IridWidgetEvent`, nested
   `timing`/`domOpts` (filter inside domOpts as `string|null`), `kind` required on
   widget / omitted on dom, narrow the ratelimit helpers to `IridDomEvent`/`DomOpts`.
4. Renames + tightenings: `inputId`→`channel`; ready `id`→`output` (optional, omit for
   app); text `value`→`string` (normalize empty→`""`); delete `__irid_state_keys`
   (preserve NULL props; plotly derives keys from props + drop client `.concat`).
5. Payload envelope: `{ id, seq, data }` (§5) — wrap on the client
   (`attachPayloadMeta`+`buildPayload`), unwrap in `irid_decode_payload`; **deletes
   `__irid_seq` AND `nonce`** (§9.8). **Add a permanent e2e**: two identical
   consecutive events (e.g. same button clicked twice, constant payload) both fire the
   server observer — locks the nonce deletion and catches a Shiny event-priority
   regression on bump (replaces the throwaway spike's finding 8).
6. Unify control-flow rendering (§11): anchor When/Match bodies as child ranges,
   emit `irid-mutate` from the When/Match mount, delete the `irid-swap` handler +
   `IridSwapMessage`. Mostly mount.R + client; e2e covers When/Match/Each.
7. Split TS into `protocol/` directory (`wire.ts` + `widget.ts` + barrel `index.ts`).
8. Fold the resolved shapes back into ARCHITECTURE.md's protocol sections, and
   **delete the throwaway spike** (`dev/spikes/protocol-serialization.R`) — its
   load-bearing findings now live in durable tests (the e2e suite + the step-5
   event-priority e2e) and the encoder's dev-mode self-assert.

---

## 11. Decisions & rejected alternatives

**No open questions** — all decided.

**Decided — split into the `protocol/` directory** (`wire.ts` + `widget.ts` + barrel
`index.ts`, §7), over a single section-layout file. Two files on the audience/stability
boundary (internal wire vs public widget API); the type *shapes* are identical either
way, so this is purely the file-organization call.

(Other resolved items, detailed below or in §9: `__irid_state_keys` deletion, branded
ids, `nonce` deletion, `irid-swap` deletion, zod, `coalesce` placement.)

**Decided — delete `irid-swap`; unify control-flow rendering on `irid-mutate`.**
When/Match are **single-slot keyed reconciliation**: they already short-circuit,
remounting only when the active branch/case *changes* and otherwise updating the body
in place via its bindings — which *is* keyed Each's "kept key → reuse, changed key →
remove+insert," with the key being the active branch instead of `by(item)`. So all
four control-flow modes are one mechanism (When = 1 slot keyed by condition; Match = 1
slot keyed by case; Each = N slots keyed by position or `by`). swap was the outlier
only because When/Match mount their body *directly* in the container range rather than
as a named child. Give the body its own child-anchor pair and a flip becomes
`mutate {removes:[old], inserts:[new]}`, an empty branch `mutate {removes:[old]}` —
swap deleted, no mode flag, one structural message, one client handler.
*Rejected* Path A (a `replace`/`clear` mode on `mutate`): a false unification — one
channel carrying two removal semantics under a flag, gaining nothing over today's two
channels (the channel name already discriminates, like `irid-attr`'s `target`).
Semantics preserved (verified vs current): flips still rebuild (widget identity/focus
still don't survive a branch flip — unchanged); same-key updates still mutate in place
(no message emitted); empty case is a remove with no insert. Cost: one comment-pair
per active When/Match body. Touches the When/Match mount in `mount.R` (emit mutate +
anchor the body) and deletes the client `irid-swap` handler — in scope because the new
wire already rewrites the client.

**Decided — delete `__irid_state_keys` by preserving NULL props (root cause).** The
field exists only because a NULL-initialized prop is dropped from the props bag (R's
`props[[k]] <- NULL` removes the key), so the plotly factory can't discover it via
`Object.keys(props)` and ships an explicit name list instead. Fix the *cause*
generically: irid's widget-init seeding keeps a NULL-valued prop as explicit `null`
(e.g. `props[k] <- list(NULL)` → jsonlite `null="null"` → `"k": null`), so every
factory sees its **full declared prop set**. plotly then iterates `Object.keys(props)`
through its existing `makeEntry` name-pattern — which already returns `null` for
`spec`/unknown ([plotly/index.ts:250](../srcts/src/widgets/plotly/index.ts#L250)) — so
no key list is needed. Generic (helps any widget), deletes the field with no
replacement, and — with the §5 envelope — removes the `__irid_*` prefix from the
protocol **entirely**. *Rejected* the alternative (lift to a top-level `stateKeys` on
`IridWidgetInitMessage`): that puts one widget's domain data on the generic widget
message — a layering violation.

**Decided — plain aliases, not branded ids.** Use plain `type ElementId = string`
etc. The aliases' real win is *documentation* of what each string resolves against,
which plain aliases give for free. Branding (nominal `string & {__brand}`) would add
enforcement, but the value is marginal here: (1) the discriminated unions already
segregate id-kinds by message variant, so cross-kind confusion isn't a structural
risk; (2) in a type-only module a brand has no runtime teeth (the encoder + e2e
catch malformed values) and is TS-only, so it doesn't strengthen the cross-language
contract the future Python server needs; (3) client-side ids are overwhelmingly
*inbound* — they'd brand for free at the typed handler boundary and widen back to
`string` for free at `getElementById`/`anchors.get`, so branding adds ceremony
without catching a bug that occurs. **Tripwire to revisit:** an actual id-kind mixup
(e.g. an `AnchorId` reaching `getElementById` → silent `null`). The codec boundary
(§9) is where a brand would be asserted if adopted, and inbound-free branding makes
it a contained, cheap reversal — so there's no cost to deferring.

**Rejected — runtime schema validation (zod/valibot) on the wire.** Keep the client
type-only. The wire is first-party and version-locked (the client is vendored into
`inst/` and ships with the server, so no untrusted producer and no version skew); a
malformed message is a bug in our own encoder, already caught by e2e. zod would also
break `protocol.ts`'s deliberate type-only/zero-runtime property (it's imported by
*both* bundles), add ~12kb gz + per-message parse cost on a substrate runtime's hot
path, and validate only the TS *client* — not the R/Python *producers*, where drift
actually originates (the language-neutral contract for that is this doc + the §9
spike, optionally a generated JSON Schema). If runtime guards are ever wanted, the
genuine third-party seam is the **widget-author API** (`defineWidget`/`setProp`/
`sendEvent`), not the internal wire — and even there prefer tiny hand-rolled asserts
or valibot over zod.
(Resolved — was "`coalesce` into `Timing`?": it stays carrier-level. `coalesce`
exists with the same meaning in every mode — immediate+coalesce is a wired,
meaningful combination ([ratelimit.ts:322,331](../srcts/src/core/ratelimit.ts#L322):
"fire eagerly, but gate on server-idle"). `mode` sets only its *default*, not its
validity. Folding it into the arms would either make immediate+coalesce
unrepresentable or duplicate it across all three arms — see the arm-vs-carrier rule
at `Timing` in §3.)

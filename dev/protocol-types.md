# Protocol Types — First-Principles Reorganization (proposal)

Status: proposal / design. Not yet implemented.

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

5. **jsonlite artifacts leak into the type.** `__irid_state_keys?: string | string[]`
   exists only because R collapses a length-1 vector to a scalar; every consumer
   must re-normalize. The fix belongs at the R boundary, not in the type.

---

## 2. First-principles model

Three axes organize everything:

- **Direction.** Server→client custom messages; client→server payloads; and the
  public author API (neither — it's a DOM/JS contract). These are three modules.
- **Shared vocabulary.** A handful of value types recur across messages —
  `EchoGate`, `DomOpts`, `Timing`, `EventKind`, and the id aliases. Name each once,
  reuse everywhere. This is what collapses "one concept, several encodings."
- **Identity.** Every `id`/channel string resolves against *something*. Give each
  referent a named alias so the type says what the string points at.
- **Default ownership.** Defaults are resolved by the **producer** (R, and the
  future Python server) into *total* values on the wire; consumers never re-derive
  them. It follows that **optionality marks semantic absence only — never
  default-elision.** A field is optional iff its absence *means* something (no
  client write to gate → no `gate`; no predicate → no `filter`; a variant simply
  lacks the field → `ms` only under throttle/debounce). A field whose "absence"
  would merely re-encode its default (`preventDefault`, `coalesce`, `clientOnly`,
  throttle `leading`, `staleTimeout`) is **required**; R already sends these
  concretely, so the client drops its defensive `!!`/coercion reads. Rationale:
  with two servers and one client, a default belongs in the producers, resolved
  once, not re-implemented per consumer ("parse, don't validate" at the boundary).

Composition over inheritance throughout: arms share a core by intersection (`&`),
and cohesive field clusters (`DomOpts`, `Timing`) are **nested members**, not
flattened in.

---

## 3. Proposed shared vocabulary (`protocol/common.ts`)

```ts
// --- Identity aliases (documentation-only; all `string`) -------------------
// Not branded — these don't change runtime or enforce at compile time; they
// document what each string resolves against. (Branding is possible but costs a
// cast at every R-boundary decode; deferred unless a real mix-up shows up.)
export type ElementId = string;   // resolves via document.getElementById
export type AnchorId  = string;   // a comment-anchor-pair id (range protocol)
export type OutputName = string;  // a Shiny output id (renderIrid / iridOutput)
export type Channel   = string;   // a Shiny input id; also the per-channel seq key

// --- Optimistic-update echo gate -------------------------------------------
// The single representation everywhere a gate travels. Carried as `gate?: EchoGate`
// (optional), NOT a tagged union `{type:'echo',…} | {type:'programmatic'}`: the
// "programmatic" state carries no payload, so a tag would just be a verbose synonym
// for `undefined` (TS already narrows `EchoGate | undefined` to block seq/channel
// access until checked), and it would force the common programmatic path to ship an
// object instead of omitting the key — also un-composing with the sparse valueGates
// map. Rule: empty alternative state → optional; data-bearing arms → union. (This is
// the mirror of the DomOpts call, where absence re-encoded a *default* → required.)
export interface EchoGate {
  seq: number;
  channel: Channel;
}

// --- DOM listener flags ----------------------------------------------------
// Mirrors R's `wire_dom_opts()`. DOM-only; a widget channel has no listener.
// Fully required, and the `domOpts` member that carries it is required too (see
// IridDomEvent): there is no semantic difference between an absent DomOpts and an
// all-false one — a "plain listener" IS the all-false record — so absence would be
// pure default-elision. R already materializes the full record on every dom row;
// the type stops under-describing it, and the client reads each flag directly
// (no `!!` coercion).
export interface DomOpts {
  preventDefault: boolean;
  stopPropagation: boolean;
  capture: boolean;
  passive: boolean;
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

## 4. Server→client messages (`protocol/messages.ts`)

The Shiny message-channel name is the discriminant *between* messages; within
`irid-attr`, `target` discriminates. No synthetic `type` field is added.

### Lifecycle

```ts
/** `irid-config` — session options pushed at start. Extensible bag. */
export interface IridConfigMessage {
  staleTimeout: number | null;   // ms before stale indicator; null disables
                                 // (R always sends it — getOption default 200)
}

/** `irid-ready` — a mount is fully wired. `output` is null for a top-level
 *  iridApp mount, the output name for renderIrid/iridOutput. (Renamed from the
 *  overloaded `id`: this is an OutputName, not an element/anchor id.) */
export interface IridReadyMessage {
  output: OutputName | null;
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
  value: unknown;
  gate?: EchoGate;          // was sequence? + channel?. Optional, but SEMANTIC
                            // absence (not elision): absent = programmatic write,
                            // no client channel to gate against. There is no
                            // "default gate" — so it stays optional by the §2 rule.
}

/** Text replacement inside a comment-anchor range. */
export interface IridAttrText {
  target: "text";
  id: AnchorId;
  // Was `string | number | null`. `number` is dead: R's coerce_text_child runs
  // as.character() before send (mount.R:500), so the wire never carries a number —
  // a reactive returning 42 arrives as "42". Tightened to `string`: the client
  // treats "", null, and undefined identically as "clear the range", so empty IS
  // the canonical clear signal — no distinct null state is needed.
  //
  // PRODUCER FIX REQUIRED to make this honest: as.character(NULL) is character(0),
  // which today serializes as `[]` (empty array), not "" — so coerce_text_child
  // must normalize the empty/NA case to "" (or NULL→clean null if we keep
  // `string | null`). Until then the truthful wire type is `string | null | []`.
  value: string;
  gate?: EchoGate;          // semantic absence, as above
}

/** Coalesced batch routed to a widget's update() hook. */
export interface IridAttrWidget {
  target: "widget";
  id: ElementId;
  values: Record<string, unknown>;        // { attr -> value }, ≥1 key
  valueGates?: Record<string, EchoGate>;  // was value_meta. Sparse: an entry only
                                          // for a key that came from a client write;
                                          // an absent key is programmatic. R sends
                                          // the map only when non-empty (mount.R:74),
                                          // so absent is the one canonical "none".
}
```

`isStaleEcho` becomes `(gate: EchoGate | undefined, seqs) => boolean` — one shape,
called identically from the dom/text path (`msg.gate`) and the widget per-key path
(`valueGates[k]`).

### Structure — comment-anchor range ops

```ts
/** `irid-swap` — replace a range's contents wholesale. */
export interface IridSwapMessage {
  id: AnchorId;
  html: string;
}

/** `irid-mutate` — granular range mutations (Each). Child ids are AnchorIds. */
export interface IridMutateMessage {
  id: AnchorId;
  removes?: AnchorId[];
  inserts?: string[];     // HTML fragments
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

/** DOM event: carries listener flags + the DOM-only escape hatches. */
export type IridDomEvent = IridEventCore & {
  source: "dom";
  domOpts: DomOpts;       // required: absent ≡ all-false, pure elision (see DomOpts)
  clientOnly: boolean;    // config-only wire: attach flags, never round-trip
  filter?: string;        // optional: absence is SEMANTIC (no predicate at all)
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
  props: WidgetProps;
}
```

---

## 5. Client→server payloads (`protocol/payloads.ts`)

```ts
/** The envelope every client->server payload carries (attachPayloadMeta).
 *  Both the irid_ev_* event path and the irid_prop_* write-back path use it. */
export interface PayloadMeta {
  id: ElementId;
  nonce: number;        // Math.random() — forces Shiny to treat repeats as new
  __irid_seq: number;   // per-channel monotonic; excluded from the user event obj
}

export type EventPayload = PayloadMeta & Record<string, unknown>;
```

`__irid_seq` keeps its prefix: it is deliberately namespaced to stay out of the
user-facing event object. (Same rationale keeps `__irid_state_keys`'s prefix; only
its *type* changes — see §6.)

---

## 6. Public widget-author API (`protocol/widget.ts`)

Separated because the audience and stability contract differ from the wire: this is
what a third-party widget author writes against.

```ts
/** Merged props handed to a factory. `__irid_state_keys` is normalized to an
 *  array at the R boundary (see §7) — no more string | string[]. */
export type WidgetProps = Record<string, unknown> & {
  __irid_state_keys?: string[];
};

export type SendEvent = (event: string, payload?: unknown) => void;
export type SetProp   = (key: string, value: unknown) => void;

export interface WidgetHandle {
  update?(values: Record<string, unknown>): void;
  destroy?(): void;
}

export type WidgetFactory = (
  el: HTMLElement,
  props: WidgetProps,
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
    "irid:ready": CustomEvent<{ id: OutputName | null }>;
  }
}
```

---

## 7. Proposed file layout

```
srcts/src/protocol/
  common.ts     identity aliases, EchoGate, DomOpts, Timing, EventKind
  messages.ts   server -> client custom messages
  payloads.ts   client -> server payloads
  widget.ts     public widget-author API + window/document globals
  index.ts      barrel: `export * from "./common"`, etc.
```

`index.ts` keeps the single import surface (`import type { … } from "../protocol"`
still works if the directory is named `protocol/` with an `index.ts`). This is a
modest split — ~220 lines into four focused files — justified by the two-audience
and direction axes, not by size. If we'd rather not split, the fallback is one file
with these as four labeled sections and the vocabulary hoisted to the top; the type
*shapes* are identical either way.

---

## 8. Wire-format changes and R-side impact

These are real protocol changes, not TS-only. Each TS change pairs with an R sender
edit so the bytes match the type:

| Concept | Wire change | R site |
|---|---|---|
| Echo gate (dom/text) | `sequence` + `channel` → nested `gate: {seq, channel}` | [mount.R](../R/mount.R) attr senders (~:464, :509) |
| Echo gate (widget) | `value_meta` → `valueGates` (rename only) | [mount.R:74-88](../R/mount.R#L74-L88) |
| Event channel | `inputId` → `channel` (rename) | [mount.R:359](../R/mount.R#L359) |
| Timing | flat `mode/ms/leading` → nested `timing` discriminated obj | [mount.R:364-366](../R/mount.R#L364-L366) |
| DOM flags | flat 4 fields → nested `domOpts`; **omit on widget rows** | [mount.R:368-371](../R/mount.R#L368-L371) |
| `kind` | drop from DOM rows entirely (already NULL→absent); required on widget | [mount.R:363](../R/mount.R#L363) |
| Ready id | `id` → `output` | [app.R:20](../R/app.R#L20) |
| state keys | `__irid_state_keys` always an array (wrap length-1) | [plotly.R:365](../R/plotly.R#L365) |
| text value | drop `number`; normalize empty/`NA`/`character(0)` → `""` so wire is `string` | [mount.R:39-500](../R/mount.R#L39) (`coerce_text_child`) |

Note `coalesce` stays a carrier-level field, now **required**: R must resolve the
NULL→mode default *before* send so the wire value is a concrete boolean. Same for
the other default-elision fields made required above (`domOpts` + its flags,
`clientOnly`, throttle `leading`, `staleTimeout`) — the producer materializes them,
and the client drops its defensive `!!`/coercion reads
([ratelimit.ts:158](../srcts/src/core/ratelimit.ts#L158), the `!!msg.coalesce`
read, etc.). This is the "producer owns defaults" rule from §2 applied concretely.

---

## 9. Serialization — SETTLED by spike

Spike: [`dev/spikes/protocol-serialization.R`](spikes/protocol-serialization.R),
run against the same `shiny:::toJSON` that `sendCustomMessage` uses (so the printed
JSON *is* the client-side shape — for server→client custom messages the client gets
`JSON.parse()` of it; `simplifyVector` only affects client→server inputs). **Pinned:
shiny 1.7.4, jsonlite 2.0.0; re-confirm on bump.** 16/16 verdicts pass. Findings:

1. **Required booleans survive.** `coalesce = FALSE`, an all-false `domOpts`, and
   `clientOnly = FALSE` all reach the client as concrete scalars — `"coalesce":false`,
   `"domOpts":{"preventDefault":false,…}`. The producer-owns-defaults decision holds:
   `FALSE` is not dropped (only `NULL` is), so the now-required fields are safe.
2. **Nests round-trip as objects.** `gate`, `timing` (incl. immediate→`{"mode":
   "immediate"}` with no ms, throttle→`{…,"ms":100,"leading":true}`), `domOpts`, and
   the per-key `valueGates` map all serialize as JSON objects. immediate+coalesce is
   representable (`"timing":{"mode":"immediate"},"coalesce":true`). Omitting
   `valueGates` (programmatic) emits no key — the sparse-map encoding works.
3. **Empty-text confirms the §8 fix is required.** `as.character(NULL)` is
   `character(0)` → serializes as `[]`; `NA_character_` → `null`; `""` → `""`. So the
   honest current wire type is `string | null | []` — `value: string` only holds
   once R normalizes empty/`NA`/`character(0)` → `""` (the §8 row).
4. **`__irid_state_keys` array-forcing confirmed.** A length-1 char vector unboxes to
   a scalar (`"xaxis_range"`, the bug); `I()` or `as.list()` forces `["xaxis_range"]`;
   length ≥2 is already an array. Use `I()` at the send site.

No surprises against the design — the only action item the spike *surfaces* (vs.
merely confirms) is the empty-text normalization, already captured in §8.

### Predictable serialization — a producer-side encoder

We cannot make jsonlite itself strict on this path: Shiny owns the `toJSON` call in
`sendCustomMessage` (`auto_unbox = TRUE`, hardcoded), with no per-message config
hook. Pre-serializing ourselves and shipping a string would double-encode and fight
Shiny's model. So predictability is a **producer-construction** concern, not a
config knob — and the spike shows the non-determinism is narrow and enumerable:

- **array-typed fields that are contingently length-1** unbox to a scalar
  (`__irid_state_keys`, `removes`/`inserts`/`order`) — shape depends on runtime
  *length*;
- **empty/sentinel values** encode by content (`NULL` dropped, `character(0)` →
  `[]`, `NA` → `null`) — shape depends on runtime *content*.

Everything else (scalars, named lists → objects) is already deterministic under
`auto_unbox = TRUE`. The strict-jsonlite idiom (`auto_unbox = FALSE` + explicit
`unbox()`) is the inverse discipline; since we can't flip the flag, we **emulate it
at construction** — make each field's wire shape a function of its *declared
protocol type*, never the runtime value:

- array fields always `I()`/`as.list()`-wrapped (length-1 can't collapse them);
- `string` fields normalize empty/`NA`/`character(0)` → `""`;
- required fields resolve `NULL` defaults to concrete values before send.

**Centralize this in one producer-side wire encoder** — a thin `irid_*` message
constructor per message type (mirroring the protocol types in §4–6) that applies the
rules, rather than scattering `I()` across every `sendCustomMessage` site. Strictness
then lives in one place that tracks the type definitions. It also gives a natural
**dev-mode assertion**: the encoder can re-parse its own output and check it against
the expected shape (or a JSON Schema generated from the protocol) in debug builds —
which would have caught the `character(0)` → `[]` wart automatically. This is the
R-side embodiment of the "producer emits total values" rule (§2).

---

## 10. Commit plan (one concept per commit, feature branch)

1. Introduce `protocol/common.ts` vocabulary (`EchoGate`, `DomOpts`, `Timing`,
   `EventKind`, id aliases); no consumers yet.
2. `EchoGate` everywhere: `gate?` on dom/text, `valueGates` on widget; collapse
   `isStaleEcho` to take a gate. (TS + R + handler together.)
3. `irid-events` union: `IridEventCore` + `IridDomEvent | IridWidgetEvent`, nested
   `timing`/`domOpts`, drop `kind` null, narrow the ratelimit helpers.
4. Renames: `inputId`→`channel`, ready `id`→`output`, `__irid_state_keys`→array.
5. Split into `protocol/` directory with barrel `index.ts`.
6. Fold the resolved shapes back into ARCHITECTURE.md's protocol sections.

Each step keeps the e2e suite green; the suite is what proves the wire still
round-trips after each rename/nest.

---

## 11. Open questions

- **Branded ids?** Plain aliases document intent but don't enforce (an `AnchorId`
  is assignable to an `ElementId`). Worth branding only if a real mix-up surfaces;
  branding adds a cast at every decode boundary.
- **Split vs single-file.** Proposal favors the `protocol/` directory; if the team
  prefers one file, the section-layout fallback in §7 gives the same shapes.
(Resolved — was "`coalesce` into `Timing`?": it stays carrier-level. `coalesce`
exists with the same meaning in every mode — immediate+coalesce is a wired,
meaningful combination ([ratelimit.ts:322,331](../srcts/src/core/ratelimit.ts#L322):
"fire eagerly, but gate on server-idle"). `mode` sets only its *default*, not its
validity. Folding it into the arms would either make immediate+coalesce
unrepresentable or duplicate it across all three arms — see the arm-vs-carrier rule
at `Timing` in §3.)

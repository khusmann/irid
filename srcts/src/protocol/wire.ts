// The irid wire contract — the single typed shape the R and (future) Python
// servers both target, and that the client implements. Both directions, and the
// vocabulary they're built from, live here: the vocabulary, then the server ->
// client messages, then the client -> server payload. The two directions are read
// jointly on a round-trip (an outbound
// `gate` is gated against the `seq` the inbound payload bumped on the same
// `channel`), so they belong together.
//
// TYPE-ONLY: declares types, no runtime code, so it is erased at build and both
// bundles import it with zero duplication.

// ---------------------------------------------------------------------------
// Vocabulary — identity aliases + the value-types every message is built from
// ---------------------------------------------------------------------------

// Identity aliases (documentation-only; all `string`; not branded). Each names
// what the string resolves against, so a message's type says what its id points at.
export type ElementId = string; // resolves via document.getElementById
export type AnchorId = string; // a comment-anchor-pair id (range protocol)
export type OutputName = string; // a Shiny output id (renderIrid / iridOutput)
export type Channel = string; // a Shiny input id; also the per-channel seq key

// --- Optimistic-update echo gate -------------------------------------------
// The single representation everywhere a gate travels: the scalar `gate: EchoGate
// | null` on a dom attr (`null` = programmatic write), and the per-key
// `valueGates: { key -> EchoGate }` on a widget batch (a key absent = programmatic).
// A gate is a *relationship* (a client send <-> its echo); a programmatic write has
// no client channel, so no gate. `isStaleEcho` treats null/absent as "apply".
export interface EchoGate {
  seq: number;
  channel: Channel;
}

// --- DOM listener options --------------------------------------------------
// Mirrors R's `wire_dom_opts(prevent_default, stop_propagation, capture, passive,
// filter)` 1:1. DOM-only; a widget channel has no listener. A fully-MATERIALIZED
// config record: every field is present, carrying its type's "off" default —
// `false` for the flags, `null` for `filter`. None is omitted, so `domOpts` itself
// is required too (an absent DomOpts would just re-encode {4 false, filter null}).
export interface DomOpts {
  preventDefault: boolean;
  stopPropagation: boolean;
  capture: boolean;
  passive: boolean;
  // JS predicate over `e`, or null for none. REQUIRED with an explicit off-default
  // — `null` is to filter what `false` is to the flags. (No "" — R forbids it.)
  filter: string | null;
}

// --- Rate-limit timing -----------------------------------------------------
// Discriminated on `mode`, mirroring R's pure wire_immediate/throttle/debounce
// shapes: ms/leading exist only where the variant gives them meaning (semantic
// absence, not elision — so they're absent by variant, required within it).
// `coalesce` is NOT here — it means the same in every mode (mode only picks its
// default), so it stays carrier-level (see IridWireCore).
export type Timing =
  | { mode: "immediate" }
  | { mode: "throttle"; ms: number; leading: boolean }
  | { mode: "debounce"; ms: number };

// ---------------------------------------------------------------------------
// Server -> client custom messages
// ---------------------------------------------------------------------------

/** `irid-config` — runtime options pushed at session start. */
export interface IridConfigMessage {
  /** ms before the stale indicator shows; `null` disables it. Materialized config
   *  field: required, with `null` its off value (R always sends it, default 200). */
  staleTimeout: number | null;
}

/** `irid-attr` — a binding update; discriminated on `target`. */
export type IridAttrMessage = IridAttrDom | IridAttrText | IridAttrWidget;

/** DOM property/attribute write on `getElementById(id)`. */
export interface IridAttrDom {
  target: "dom";
  id: ElementId;
  attr: string;
  value: unknown;
  /** Always present: the echo gate, or `null` for a programmatic write (no client
   *  channel to gate against). Only dom carries it (value/checked echoes on focused
   *  inputs); text never does. `isStaleEcho` treats `null` as "apply". */
  gate: EchoGate | null;
}

/** Text replacement inside a comment-anchor range. NO gate — a comment-anchor
 *  range is display-only (you can't type into it), so a text echo is always
 *  programmatic and applies unconditionally. */
export interface IridAttrText {
  target: "text";
  id: AnchorId;
  /** `string`, not `string | number | null`: `number` is dead (R runs
   *  `as.character()` before send), and the producer normalizes empty/NA to `""`
   *  (the canonical clear signal), so the wire type is exactly `string`. */
  value: string;
}

/** Coalesced batch routed to a widget's `update()` hook. */
export interface IridAttrWidget {
  target: "widget";
  id: ElementId;
  /** `{ attr -> value }`, one or more keys coalesced in one server flush. The
   *  DATA — always present. */
  values: Record<string, unknown>;
  /** Sparse per-key gate ANNOTATION: an entry only for a key from a client write;
   *  an absent key is programmatic. Always present — empty `{}` when no key is
   *  gated, which the per-key lookup treats identically to omission. */
  valueGates: Record<string, EchoGate>;
}

/**
 * `irid-mutate` — granular comment-anchor range mutations. The sole structural
 * message: drives `Each` (N keyed/positional children) AND `When`/`Match` (one
 * child, keyed by active branch/case). removes/inserts/order are always present:
 * a command-part this mutation doesn't do is an empty array, not an omitted
 * field. The handler iterates each, so `[]` is a no-op — a uniform shape.
 */
export interface IridMutateMessage {
  id: AnchorId;
  removes: AnchorId[];
  inserts: string[];
  order: AnchorId[];
}

/**
 * One `irid-wire` entry — the serialized per-slot `wire()` carrier for one
 * channel; the message is an array of these. A discriminated union on `source`: a
 * DOM event carries listener options; the widget arm adds nothing. This makes the
 * illegal states unrepresentable — a throttle with no `ms` won't type, and DOM
 * flags don't exist on the widget arm.
 */
export interface IridWireCore {
  id: ElementId;
  /** The DOM/widget event NAME. */
  event: string;
  /** The Shiny input id the client sends on AND the per-channel sequence key.
   *  Replaces the old `inputId` — one name for one value. */
  channel: Channel;
  /** Nested timing; `ms`/`leading` live inside per mode. */
  timing: Timing;
  /** Carrier-level (orthogonal to mode); R resolves NULL -> mode default. */
  coalesce: boolean;
}

/** DOM event: the listener options (incl. filter) + the config-only flag. */
export type IridWireDom = IridWireCore & {
  source: "dom";
  /** Carries the flags AND filter (= R's `wire_dom_opts`). */
  domOpts: DomOpts;
  /** Config-only wire: attach flags, never round-trip. */
  clientOnly: boolean;
};

/** Widget event: no DOM flags (no listener is attached), no extra fields. */
export type IridWireWidget = IridWireCore & {
  source: "widget";
};

export type IridWire = IridWireDom | IridWireWidget;

/** `irid-widget-init` — mount a widget instance into its container. */
export interface IridWidgetInitMessage {
  id: ElementId;
  name: string;
  props: Record<string, unknown>;
}

/**
 * `irid-ready` — a mount is fully wired (listeners attached, server observers
 * registered). `output` is the output name for a `renderIrid`/`iridOutput` mount,
 * and `null` for a top-level `iridApp` mount (no output name exists). Always
 * present: this is the same `name | null` the public `irid:ready` detail exposes,
 * so the wire and the public event share one encoding.
 */
export interface IridReadyMessage {
  output: OutputName | null;
}

// ---------------------------------------------------------------------------
// Client -> server payloads
// ---------------------------------------------------------------------------

/**
 * What goes on the wire for every client->server payload: irid's transport
 * envelope owning the top level, with the foreign-keyed event data under `data`
 * (DOM event fields, or a widget author's sendEvent payload). No `nonce` (event-
 * priority bypasses Shiny's dedup, so it was vestigial) and no `__irid_*` prefix
 * (the envelope gives irid sole ownership of the top level). The R partner is
 * `irid_decode_payload`.
 */
export interface EventPayload {
  /** Source element id (carried explicitly — robust under Shiny-module namespacing). */
  id: ElementId;
  /** Per-channel monotonic sequence (the echo gate). */
  seq: number;
  data: Record<string, unknown>;
}

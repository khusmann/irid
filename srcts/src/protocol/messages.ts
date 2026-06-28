// The irid wire messages — the typed shapes the R and (future) Python servers
// both target, and the client implements: the server -> client custom messages,
// then the client -> server payload. The two directions are read jointly on a
// round-trip (an outbound `gate` is gated against the `seq` the inbound payload
// bumped on the same `channel`), so they belong together. The value-types they're
// built from live in `./values`.
//
// TYPE-ONLY: declares types, no runtime code, so it is erased at build and both
// bundles import it with zero duplication.

import type {
  ElementId,
  AnchorId,
  OutputName,
  Channel,
  EchoGate,
  DomOpts,
  Timing,
} from "./values";

// ---------------------------------------------------------------------------
// Server -> client custom messages
// ---------------------------------------------------------------------------

/** `irid-config` — runtime options pushed at session start. */
export interface IridConfig {
  /** ms before the stale indicator shows; `null` disables it. Materialized config
   *  field: required, with `null` its off value (R always sends it, default 200). */
  staleTimeout: number | null;
}

/** `irid-attr` — a binding update; discriminated on `target`. */
export type IridAttr = IridAttrDom | IridAttrText | IridAttrWidget;

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
  /** The producer normalizes empty/NA to `""` (the canonical clear signal), so
   *  the wire type is exactly `string`. */
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
export interface IridMutate {
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
  /** The Shiny input id the client sends on AND the per-channel sequence key. */
  channel: Channel;
  /** Nested timing; `ms`/`leading` live inside per mode. */
  timing: Timing;
  /** Carrier-level (orthogonal to mode); R resolves NULL -> mode default. */
  coalesce: boolean;
}

/** DOM event: the listener options (incl. filter) + the config-only flag. */
export interface IridWireDom extends IridWireCore {
  source: "dom";
  /** Carries the flags AND filter (= R's `wire_dom_opts`). */
  domOpts: DomOpts;
  /** Config-only wire: attach flags, never round-trip. */
  clientOnly: boolean;
}

/** Widget event: no DOM flags (no listener is attached), no extra fields. */
export interface IridWireWidget extends IridWireCore {
  source: "widget";
}

export type IridWire = IridWireDom | IridWireWidget;

/** `irid-widget-init` — mount a widget instance into its container. */
export interface IridWidgetInit {
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
export interface IridReady {
  output: OutputName | null;
}

// ---------------------------------------------------------------------------
// Client -> server payloads
// ---------------------------------------------------------------------------

/**
 * What goes on the wire for every client->server payload: irid's transport
 * envelope owning the top level, with the foreign-keyed event data under `data`
 * (DOM event fields, or a widget author's sendEvent payload). No `__irid_*` prefix
 * — the envelope gives irid sole ownership of the top level. The R partner reads
 * these envelope fields directly (`coerce_value_as_number` applies the one inbound
 * normalization).
 */
export interface EventPayload {
  /** Source element id (carried explicitly — robust under Shiny-module namespacing). */
  id: ElementId;
  /** Per-channel monotonic sequence (the echo gate). */
  seq: number;
  data: Record<string, unknown>;
}

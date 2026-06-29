// The irid protocol messages: server -> client custom messages, then the client ->
// server payload. Both directions live together — they're read jointly on a
// round-trip (an outbound `gate` is checked against the `seq` the inbound payload
// bumped on the same `channel`). Type-only (erased at build).

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
//
// Three messages: `irid-config` (runtime options, applied on receipt),
// `irid-render` (every DOM/widget update of one flush), `irid-ready` (post-render
// barrier). `irid-render` carries an ordered op list applied in one synchronous
// pass.

/**
 * `irid-config` — runtime options, applied on receipt (the handler just sets the
 * current value). Carries no ordering dependency, so it may arrive at any time;
 * in practice it's emitted at each mount entry point (an `iridApp` server at
 * session start, a `renderIrid` on each render flush — so mid-session for outputs
 * that render or re-render later).
 */
export interface IridConfig {
  /** ms before the stale indicator shows; `null` disables it. */
  staleTimeout: number | null;
}

/**
 * `irid-render` — one flush's render: an ordered op list applied in one
 * synchronous pass (one paint). Emission order is apply order — a child's
 * `mutate` precedes the `wire`/`widget-init`/`attr` that need its element.
 */
export interface IridRender {
  ops: Op[];
}

export type Op = OpMutate | OpWire | OpWidgetInit | OpAttr | OpText;

/**
 * Structural comment-anchor range mutation, driving `Each` and `When`/`Match`.
 * Each part is always present; an unused part is `[]` (a no-op). The three arrays
 * are the ordered phases of ONE reconciliation.
 */
export interface OpMutate {
  kind: "mutate";
  id: AnchorId;
  removes: AnchorId[];
  inserts: string[];
  order: AnchorId[];
}

/**
 * Attach one client->server channel's listener (one op per channel).
 * Discriminated on `source` — where the event comes FROM (the mirror of
 * `OpAttr.target`): a DOM listener or a widget.
 */
export interface OpWireCore {
  kind: "wire";
  id: ElementId;
  /** The DOM/widget event name. */
  event: string;
  /** The Shiny input id the client sends on; also the per-channel seq key. */
  channel: Channel;
  timing: Timing;
  coalesce: boolean;
}

/** DOM event: listener options + the config-only flag. */
export interface OpWireDom extends OpWireCore {
  source: "dom";
  domOpts: DomOpts;
  /** Config-only wire: attach flags, never round-trips. */
  clientOnly: boolean;
}

/** Widget event: no listener attached, no extra fields. */
export interface OpWireWidget extends OpWireCore {
  source: "widget";
}

export type OpWire = OpWireDom | OpWireWidget;

/** Mount a widget instance into its container. */
export interface OpWidgetInit {
  kind: "widget-init";
  id: ElementId;
  name: string;
  /** Merged initial props (`{}` when none); NULL-valued keys kept as `null`. */
  props: Record<string, unknown>;
}

/**
 * A bound value pushed to its sink, discriminated on `target` — where it GOES.
 *   "dom"    — property/attribute write on `getElementById(id)`, applied inline.
 *   "widget" — a single-key prop write; the client collects all `target="widget"`
 *              ops per id and calls `update()` once at the end with the merged map
 *              (one redraw).
 */
export interface OpAttr {
  kind: "attr";
  target: "dom" | "widget";
  id: ElementId;
  attr: string;
  value: unknown;
  /** The echo gate, or `null` for a programmatic write. */
  gate: EchoGate | null;
}

/**
 * Text replace inside a comment-anchor range — its own kind (no `attr`, no
 * `gate`). `value` is always a string; `""` is the canonical "clear the range"
 * signal.
 */
export interface OpText {
  kind: "text";
  id: AnchorId;
  value: string;
}

/**
 * `irid-ready` — a mount is fully wired (post-render barrier). Sent after
 * `irid-render` drains, so a client that has seen it has the whole render
 * applied. `output` is the output name for a `renderIrid`/`iridOutput` mount,
 * `null` for a top-level `iridApp` mount.
 */
export interface IridReady {
  output: OutputName | null;
}

// ---------------------------------------------------------------------------
// Client -> server payloads
// ---------------------------------------------------------------------------

/**
 * Every client->server payload: irid's transport envelope, with the event data
 * (DOM event fields, or a widget's sendEvent payload) under `data`.
 */
export interface IridClientEvent {
  /** Source element id (carried explicitly for Shiny-module namespacing). */
  id: ElementId;
  /** Per-channel monotonic sequence (the echo gate). */
  seq: number;
  data: Record<string, unknown>;
}

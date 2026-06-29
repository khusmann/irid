// The irid wire messages: server -> client custom messages, then the client ->
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

/** `irid-config` — runtime options pushed at session start. */
export interface IridConfig {
  /** ms before the stale indicator shows; `null` disables it. */
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
  /** The echo gate, or `null` for a programmatic write. */
  gate: EchoGate | null;
}

/** Text replacement inside a comment-anchor range. No gate — a range is
 *  display-only, so a text echo is always programmatic. */
export interface IridAttrText {
  target: "text";
  id: AnchorId;
  /** Empty/NA normalized to `""` (the clear signal). */
  value: string;
}

/** Coalesced batch routed to a widget's `update()` hook. */
export interface IridAttrWidget {
  target: "widget";
  id: ElementId;
  /** `{ attr -> value }`, keys coalesced in one server flush. */
  values: Record<string, unknown>;
  /** Sparse per-key gate; an absent key is programmatic. */
  valueGates: Record<string, EchoGate>;
}

/**
 * `irid-mutate` — structural comment-anchor range mutations, driving `Each` and
 * `When`/`Match`. Each part is always present; an unused part is `[]` (a no-op).
 */
export interface IridMutate {
  id: AnchorId;
  removes: AnchorId[];
  inserts: string[];
  order: AnchorId[];
}

/**
 * One `irid-wire` entry — the per-channel `wire()` carrier; the message is an
 * array of these. Discriminated on `source`: a DOM event carries listener
 * options, the widget arm adds nothing.
 */
export interface IridWireCore {
  id: ElementId;
  /** The DOM/widget event name. */
  event: string;
  /** The Shiny input id the client sends on; also the per-channel seq key. */
  channel: Channel;
  timing: Timing;
  coalesce: boolean;
}

/** DOM event: listener options + the config-only flag. */
export interface IridWireDom extends IridWireCore {
  source: "dom";
  domOpts: DomOpts;
  /** Config-only wire: attach flags, never round-trips. */
  clientOnly: boolean;
}

/** Widget event: no listener attached, no extra fields. */
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
 * `irid-ready` — a mount is fully wired. `output` is the output name for a
 * `renderIrid`/`iridOutput` mount, `null` for a top-level `iridApp` mount.
 */
export interface IridReady {
  output: OutputName | null;
}

/**
 * `irid-batch` — an ordered envelope coalescing the render-phase messages of one
 * server flush into a single frame the client applies in one synchronous pass
 * (one paint). Each op is replayed through the same per-type apply logic as its
 * standalone message; `type` discriminates which. Emission order is apply order,
 * preserving the mutate-before-wire/init/attr dependency.
 */
export interface IridBatchOp {
  type: "irid-mutate" | "irid-attr" | "irid-wire" | "irid-widget-init";
  message: IridMutate | IridAttr | IridWire[] | IridWidgetInit;
}

export interface IridBatch {
  ops: IridBatchOp[];
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

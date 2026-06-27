// The irid wire protocol + public client API — the single typed contract that the
// R and (future) Python servers both target, and that the client implements.
//
// TYPE-ONLY: this file declares types and one global augmentation, no runtime code,
// so it is erased at build and both bundles import it with zero duplication. Import
// from it with `import type { … } from "../protocol"`.
//
// Shapes are documented in ARCHITECTURE.md's "Client-Side Protocol" / "Widgets"
// sections; this is their machine-checked form.

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
// The single representation everywhere a gate travels. Carried as `gate?: EchoGate`
// (omitted/undefined for a programmatic write), NOT `EchoGate | null` and NOT a
// tagged union. A gate is a *relationship* (a client send <-> its echo), so its
// absence is CONTEXTUAL — a programmatic write has no client channel, so no gate.
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
// default), so it stays carrier-level (see IridEventCore).
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
  /** CONTEXTUAL absence: omitted for a programmatic write (no client channel to
   *  gate against). Only dom carries it (value/checked echoes on focused inputs);
   *  text never does. */
  gate?: EchoGate;
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
   *  an absent key is programmatic. Omitted (not present-empty `{}`) when no key
   *  is gated — matches the scalar `gate`. */
  valueGates?: Record<string, EchoGate>;
}

/**
 * `irid-mutate` — granular comment-anchor range mutations. The sole structural
 * message: drives `Each` (N keyed/positional children) AND `When`/`Match` (one
 * child, keyed by active branch/case). removes/inserts/order are contextual
 * command-parts, each omitted when this mutation doesn't do it.
 */
export interface IridMutateMessage {
  id: AnchorId;
  removes?: AnchorId[];
  inserts?: string[];
  order?: AnchorId[];
}

/**
 * For widget channels, which kind of stream: a two-way prop write-back
 * (`irid_prop_*`) or a notification (`irid_ev_*`). No `null` — absence is carried
 * by the field living on the widget arm only.
 */
export type EventKind = "prop" | "event";

/**
 * One `irid-events` registration entry; the message is an array of these. A
 * discriminated union on `source`: a DOM event carries listener options, a widget
 * event carries its stream `kind`. This makes the illegal states unrepresentable —
 * a throttle with no `ms` won't type, DOM flags don't exist on the widget arm, and
 * `kind` is required-without-null on the widget arm and absent on the dom arm.
 */
export interface IridEventCore {
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
export type IridDomEvent = IridEventCore & {
  source: "dom";
  /** Carries the flags AND filter (= R's `wire_dom_opts`). */
  domOpts: DomOpts;
  /** Config-only wire: attach flags, never round-trip. */
  clientOnly: boolean;
};

/** Widget event: carries kind; no DOM flags (no listener is attached). */
export type IridWidgetEvent = IridEventCore & {
  source: "widget";
  kind: EventKind;
};

export type IridEventEntry = IridDomEvent | IridWidgetEvent;

/** `irid-widget-init` — mount a widget instance into its container. */
export interface IridWidgetInitMessage {
  id: ElementId;
  name: string;
  props: Record<string, unknown>;
}

/**
 * `irid-ready` — a mount is fully wired (listeners attached, server observers
 * registered). `output` is the output name for a `renderIrid`/`iridOutput` mount,
 * and ABSENT for a top-level `iridApp` mount (no output name exists). Optional, not
 * `| null`: top-level is semantic absence, one canonical encoding. The client maps
 * absent -> null only when synthesizing the public `irid:ready` detail.
 */
export interface IridReadyMessage {
  output?: OutputName;
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

// ---------------------------------------------------------------------------
// Public client API (window.irid) + widget-author contract
// ---------------------------------------------------------------------------

/** Push a widget notification (no-op if no R subscriber). */
export type SendEvent = (event: string, payload?: unknown) => void;

/** Push a two-way prop's new value (no-op if no R subscriber). */
export type SetProp = (key: string, value: unknown) => void;

/** What a factory returns (directly or as a Promise). Both members optional. */
export interface WidgetHandle {
  /** Server->client batch: `{ attr -> value }` for keys that changed in a flush. */
  update?(values: Record<string, unknown>): void;
  /** Runs before the container is detached. */
  destroy?(): void;
}

/**
 * Widget factory: runs once per mount with the (attached) container element, the
 * merged props, and the two client->server pushers. May be async (return a
 * Promise of the handle) to await a library global / import / WASM init.
 */
export type WidgetFactory = (
  el: HTMLElement,
  /** All declared props, callable and constant alike. The factory sees EVERY prop
   *  it declared — including NULL-initialized reactives, which arrive as explicit
   *  `null`, not absent. plotly relies on this to derive its state args from the
   *  prop set. */
  props: Record<string, unknown>,
  sendEvent: SendEvent,
  setProp: SetProp,
) => WidgetHandle | Promise<WidgetHandle>;

/** The public `window.irid` surface. */
export interface Irid {
  defineWidget(name: string, factory: WidgetFactory): void;
}

declare global {
  interface Window {
    irid: Irid;
    /**
     * Set true once at least one mount is fully wired (listeners attached,
     * server observers registered). The escape hatch for code that may attach
     * its `irid:ready` listener too late to catch the event:
     *
     *   if (window.__iridReady) init();
     *   else document.addEventListener("irid:ready", init);
     *
     * The e2e harness waits on this before the first interaction (helper-e2e.R).
     */
    __iridReady?: boolean;
  }
  interface DocumentEventMap {
    /**
     * Fired on `document` each time an irid mount becomes interactive.
     * `detail.id` is the output name (`renderIrid`/`iridOutput`) or `null`
     * (top-level `iridApp`). The public "irid is ready" lifecycle hook.
     */
    "irid:ready": CustomEvent<{ id: string | null }>;
  }
}

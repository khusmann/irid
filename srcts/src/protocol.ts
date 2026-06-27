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
  /** ms before the stale indicator shows; `null` disables it. */
  staleTimeout?: number | null;
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
  value: string | number | null;
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

/** `irid-swap` — replace a comment-anchor range's contents wholesale. */
export interface IridSwapMessage {
  id: string;
  html: string;
}

/** `irid-mutate` — granular range mutations (used by `Each`). */
export interface IridMutateMessage {
  id: string;
  removes?: string[];
  inserts?: string[];
  order?: string[];
}

/** How a client->server stream is rate-limited. */
export type EventMode = "immediate" | "throttle" | "debounce";

/** Whether an event originates from a DOM listener or a widget channel. */
export type EventSource = "dom" | "widget";

/**
 * For widget channels, which kind of stream: a two-way prop write-back
 * (`irid_prop_*`) or a notification (`irid_ev_*`). `null`/absent for DOM events.
 */
export type EventKind = "prop" | "event" | null;

/** One `irid-events` registration entry. The message is an array of these. */
export interface IridEventEntry {
  id: string;
  event: string;
  /** Namespaced send target; also the per-channel sequence key. */
  inputId: string;
  source: EventSource;
  kind?: EventKind;
  mode: EventMode;
  /** Rate-limit window (throttle/debounce). */
  ms?: number;
  /** Throttle leading-edge fire. */
  leading?: boolean;
  /** Gate sends on server-idle (backpressure). */
  coalesce?: boolean;
  preventDefault?: boolean;
  stopPropagation?: boolean;
  capture?: boolean;
  passive?: boolean;
  /** A config-only wire (DOM flags, no round-trip). */
  clientOnly?: boolean;
  /** JS expression over the DOM event `e`, compiled to a drop-predicate. */
  filter?: string;
}

/** `irid-widget-init` — mount a widget instance into its container. */
export interface IridWidgetInitMessage {
  id: string;
  name: string;
  props: WidgetProps;
}

/**
 * `irid-ready` — a mount is fully wired (listeners attached, server observers
 * registered). `id` is the output name for a `renderIrid`/`iridOutput` mount,
 * absent for a top-level `iridApp` mount.
 */
export interface IridReadyMessage {
  id?: string | null;
}

// ---------------------------------------------------------------------------
// Client -> server payloads
// ---------------------------------------------------------------------------

/** The envelope every client->server payload carries (see `attachPayloadMeta`). */
export interface PayloadMeta {
  id: string;
  nonce: number;
  /** Per-channel monotonic sequence; excluded from the user-facing event object. */
  __irid_seq: number;
}

/** A dispatched event payload: the envelope plus event/element fields. */
export type EventPayload = PayloadMeta & Record<string, unknown>;

// ---------------------------------------------------------------------------
// Public client API (window.irid) + widget-author contract
// ---------------------------------------------------------------------------

/**
 * The merged props object handed to a factory: all props (callable and constant
 * alike) flattened. `__irid_state_keys` lists state args that may have been
 * dropped from the object when `null`-initialized.
 */
export type WidgetProps = Record<string, unknown> & {
  __irid_state_keys?: string | string[];
};

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
  props: WidgetProps,
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

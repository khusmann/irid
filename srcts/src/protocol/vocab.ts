// The irid protocol vocabulary — the identity aliases + value-types every wire
// message is built from. Unprefixed (not `Irid*`) on purpose: these are reusable
// building blocks, not messages (the `Irid*` message shapes live in `./messages`).
//
// TYPE-ONLY: declares types, no runtime code, so it is erased at build and both
// bundles import it with zero duplication.

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
// default), so it stays carrier-level (see IridWireCore in ./messages).
export type Timing =
  | { mode: "immediate" }
  | { mode: "throttle"; ms: number; leading: boolean }
  | { mode: "debounce"; ms: number };

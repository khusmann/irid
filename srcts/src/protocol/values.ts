// Protocol value-types: the id aliases + value objects every wire message is
// built from. Type-only (erased at build).

// Id aliases — all `string`, named for what they resolve against.
export type ElementId = string; // document.getElementById
export type AnchorId = string; // a comment-anchor-pair id (range protocol)
export type OutputName = string; // a Shiny output id (renderIrid / iridOutput)
export type Channel = string; // a Shiny input id; also the per-channel seq key

// --- Optimistic-update echo gate -------------------------------------------
// Pairs a client send with its echo. `isStaleEcho` treats a missing gate
// (null/absent) as a programmatic write, applied unconditionally.
export interface EchoGate {
  seq: number;
  channel: Channel;
}

// --- DOM listener options --------------------------------------------------
// Mirrors R's `wire_dom_opts()`. DOM-only (a widget channel has no listener).
// Every field present with its off-default: `false` for the flags, `null` for
// `filter`.
export interface DomOpts {
  preventDefault: boolean;
  stopPropagation: boolean;
  capture: boolean;
  passive: boolean;
  filter: string | null; // JS predicate over `e`, or null for none
}

// --- Rate-limit timing -----------------------------------------------------
// Discriminated on `mode`; `ms`/`leading` exist only where the variant gives
// them meaning. `coalesce` is carrier-level (see IridWireCore), not here.
export type Timing =
  | { mode: "immediate" }
  | { mode: "throttle"; ms: number; leading: boolean }
  | { mode: "debounce"; ms: number };

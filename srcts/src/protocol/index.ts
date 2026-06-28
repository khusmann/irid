// Import surface for the typed protocol. Three files split by role:
//   - values.ts   — value-types + id aliases every message is built from
//   - messages.ts — the wire messages (both directions)
//   - widget.ts   — the public widget-author API
export * from "./values";
export * from "./messages";
export * from "./widget";

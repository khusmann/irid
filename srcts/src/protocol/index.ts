// The single import surface for the typed protocol: `import type { … } from
// "../protocol"` resolves here. Three files split by role:
//   - values.ts   — the value-types + id aliases every message is built from
//   - messages.ts — the wire messages (both directions), built on values
//   - widget.ts   — the public widget-author API
// `Irid`-prefixed names are messages (messages.ts); unprefixed names are
// value-types (values.ts). widget.ts references nothing from the other two.
export * from "./values";
export * from "./messages";
export * from "./widget";

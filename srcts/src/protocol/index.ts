// The single import surface for the typed protocol: `import type { … } from
// "../protocol"` resolves here. Three files split by role:
//   - vocab.ts    — the value-types + id aliases every message is built from
//   - messages.ts — the wire messages (both directions), built on vocab
//   - widget.ts   — the public widget-author API
// `Irid`-prefixed names are messages (messages.ts); unprefixed names are
// vocabulary (vocab.ts). widget.ts references nothing from the other two.
export * from "./vocab";
export * from "./messages";
export * from "./widget";

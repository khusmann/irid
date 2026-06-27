// The single import surface for the typed protocol: `import type { … } from
// "../protocol"` resolves here. Two substantive files split on audience/stability
// — the internal wire contract vs the public widget-author API (see ARCHITECTURE.md
// §7). There is no `common.ts`: every value-type and id alias is wire-only, and
// widget.ts references nothing from wire.ts.
export * from "./wire";
export * from "./widget";

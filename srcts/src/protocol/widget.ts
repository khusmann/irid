// The public widget-author API + the `window.irid` / `document` globals. Separated
// from wire.ts because the audience and stability contract differ: this is what a
// third-party widget author writes against. It references NOTHING from wire.ts —
// its one would-be cross-reference (the `irid:ready` detail) uses plain `string`
// (see below), so the two files don't couple, and there is no shared `common.ts`.
//
// TYPE-ONLY: declares types and one global augmentation, no runtime code.

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
     * (top-level `iridApp`). Plain `string`, not the wire's `OutputName`: importing
     * one alias across files isn't worth re-coupling widget.ts to wire.ts.
     */
    "irid:ready": CustomEvent<{ id: string | null }>;
  }
}

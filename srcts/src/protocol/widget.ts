// The public widget-author API + the `window.irid` / `document` globals. Kept
// separate from the wire contract: this is the third-party-facing surface, and
// it references nothing from messages.ts/values.ts. Type-only.

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
 * Widget factory: runs once per mount with the attached container element, the
 * merged props, and the two client->server pushers. May be async.
 */
export type WidgetFactory = (
  el: HTMLElement,
  /** Every declared prop, including NULL-initialized reactives (explicit `null`,
   *  not absent). */
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
     * Set true once at least one mount is fully wired. Escape hatch for code
     * that may attach its `irid:ready` listener too late to catch the event:
     *
     *   if (window.__iridReady) init();
     *   else document.addEventListener("irid:ready", init);
     */
    __iridReady?: boolean;
  }
  interface DocumentEventMap {
    /**
     * Fired on `document` each time an irid mount becomes interactive.
     * `detail.id` is the output name (`renderIrid`/`iridOutput`) or `null`
     * (top-level `iridApp`).
     */
    "irid:ready": CustomEvent<{ id: string | null }>;
  }
}

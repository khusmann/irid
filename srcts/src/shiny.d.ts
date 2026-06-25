// Minimal ambient declarations for the untyped globals the irid client touches:
// the Shiny client object and jQuery's `$` (used for shiny:idle/busy and the
// Shiny.bindAll/unbindAll adjacency). Only the members irid actually uses — this
// is deliberately NOT a full typing of Shiny or jQuery. Keep it import/export-free
// so it stays an ambient (global) declaration. See dev/srcts-migration.md.

interface ShinyInputOpts {
  priority?: "event" | "deferred" | "immediate";
}

interface ShinyClient {
  addCustomMessageHandler(type: string, handler: (message: any) => void): void;
  setInputValue(id: string, value: unknown, opts?: ShinyInputOpts): void;
  bindAll(scope?: Element | Document): void;
  unbindAll(scope: Element | Document): void;
  shinyapp?: { $idleTimeout?: number };
}

declare const Shiny: ShinyClient;

// Just the jQuery surface irid uses: $(target).on(...) / .one(...).
interface IridJQuery {
  on(event: string, handler: (...args: any[]) => void): IridJQuery;
  one(event: string, handler: (...args: any[]) => void): IridJQuery;
}
declare function $(target: Document | Element): IridJQuery;

// Widget registry & lifecycle. `defined` maps a registry name to its factory;
// inits that arrive before the factory loads are buffered under pendingInits and
// drained when defineWidget lands. `widgets` is the live per-id table.
//
// A factory may be SYNCHRONOUS (returns the handle) or ASYNCHRONOUS (returns a
// Promise of it). The entry is created synchronously at mount with handle = null;
// `pending` buffers updates that land during async construction; `destroyed`
// records a teardown mid-construction so the resolved handle is disposed, not
// adopted.

import { sendWidgetEvent, setWidgetProp } from "./ratelimit";
import type {
  IridWidgetInit,
  SendEvent,
  SetProp,
  WidgetFactory,
  WidgetHandle,
} from "../protocol";

interface WidgetEntry {
  handle: WidgetHandle | null;
  name: string;
  pending: Record<string, unknown> | null;
  destroyed: boolean;
}

const defined = new Map<string, WidgetFactory>();
const pendingInits: Record<string, Array<{ id: string; props: Record<string, unknown> }>> =
  {};
export const widgets: Record<string, WidgetEntry> = {};

function mountWidget(
  id: string,
  name: string,
  props: Record<string, unknown>,
  factory: WidgetFactory,
): void {
  if (widgets[id]) return; // idempotent — duplicate init (in-flight or live)
  const el = document.getElementById(id);
  if (!el) {
    console.warn("irid: widget container not found for id=" + id);
    return;
  }
  const sendEvent: SendEvent = (event, payload) => {
    sendWidgetEvent(id, event, payload as Record<string, unknown> | undefined);
  };
  const setProp: SetProp = (key, value) => {
    setWidgetProp(id, key, value);
  };
  // Reserve the id synchronously so a duplicate init is idempotent, an attr
  // arriving mid-construction buffers, and a teardown mid-construction is recorded.
  const entry: WidgetEntry = {
    handle: null,
    name,
    pending: null,
    destroyed: false,
  };
  widgets[id] = entry;

  // Adopt the resolved handle — unless the widget was torn down (or its id
  // re-mounted) while an async factory was still constructing, in which case
  // dispose the just-built handle instead of registering a zombie.
  function commit(handle: WidgetHandle | undefined | null): void {
    const h: WidgetHandle = handle || {};
    if (entry.destroyed || widgets[id] !== entry) {
      if (typeof h.destroy === "function") {
        try {
          h.destroy();
        } catch (e) {
          console.error(e);
        }
      }
      return;
    }
    entry.handle = h;
    if (entry.pending) {
      if (typeof h.update === "function") h.update(entry.pending);
      entry.pending = null;
    }
  }

  // A factory may return the handle directly (sync) or a Promise of it (async).
  let result: WidgetHandle | Promise<WidgetHandle>;
  try {
    result = factory(el, props, sendEvent, setProp);
  } catch (e) {
    console.error("irid: widget factory threw for " + name, e);
    if (widgets[id] === entry) delete widgets[id];
    return;
  }
  if (result && typeof (result as Promise<WidgetHandle>).then === "function") {
    (result as Promise<WidgetHandle>).then(commit, (err) => {
      console.error("irid: widget factory failed for " + name, err);
      if (widgets[id] === entry) delete widgets[id];
    });
  } else {
    commit(result as WidgetHandle);
  }
}

// Tear down one widget id: run its destroy hook if the handle has committed, and
// flag the entry so an async factory still in flight disposes its handle.
function destroyWidget(id: string): void {
  const w = widgets[id];
  if (!w) return;
  w.destroyed = true;
  if (w.handle && typeof w.handle.destroy === "function") {
    try {
      w.handle.destroy();
    } catch (e) {
      console.error(e);
    }
  }
  delete widgets[id];
}

// Destroy any widget instances inside `root`. Called from detachRange
// BEFORE Shiny.unbindAll so destroy() runs while the subtree is intact.
export function destroyWidgetsIn(root: Node): void {
  if (
    root.nodeType === 1 &&
    (root as Element).hasAttribute("data-irid-widget")
  ) {
    destroyWidget((root as Element).id);
  }
  if (typeof (root as Element).querySelectorAll === "function") {
    const els = (root as Element).querySelectorAll("[data-irid-widget]");
    for (let i = 0; i < els.length; i++) destroyWidget(els[i].id);
  }
}

// defineWidget(name, factory) — see the JS-side widget API in ARCHITECTURE.md.
export function defineWidget(name: string, factory: WidgetFactory): void {
  defined.set(name, factory);
  const queue = pendingInits[name];
  if (queue) {
    delete pendingInits[name];
    queue.forEach((init) => {
      mountWidget(init.id, name, init.props, factory);
    });
  }
}

// The `irid-widget-init` handler body. The init carries no deps — the factory
// script is delivered via insertUI at mount time, so window.irid exists when it
// calls defineWidget. An init that still beats its factory parks under
// pendingInits and drains on defineWidget.
export function handleWidgetInit(msg: IridWidgetInit): void {
  if (widgets[msg.id]) return; // idempotent
  const factory = defined.get(msg.name);
  if (!factory) {
    if (!pendingInits[msg.name]) pendingInits[msg.name] = [];
    pendingInits[msg.name].push({ id: msg.id, props: msg.props });
    return;
  }
  mountWidget(msg.id, msg.name, msg.props, factory);
}

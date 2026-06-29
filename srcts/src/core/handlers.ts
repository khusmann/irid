// The Shiny custom-message handlers that drive the client: irid-config,
// irid-render, irid-ready.
//
// `irid-render` carries one flush's ordered op list, applied in one synchronous
// pass (one paint). Each op is dispatched to its `apply*` function; emission
// order is apply order, so a child's `mutate` precedes the `wire`/`widget-init`/
// `attr` that depend on its element. `target="widget"` attrs are accumulated per
// id and flushed once at the end (one `update()` call → one redraw).

import { isStaleEcho, sequences } from "./seq";
import {
  anchors,
  detachRange,
  indexAnchors,
  lookupAnchors,
  parseFragment,
  unregisterAnchorsIn,
} from "./anchors";
import { handleWidgetInit, widgets } from "./widgets";
import {
  attachListener,
  managed,
  setupDebounce,
  setupImmediate,
  setupThrottle,
  widgetStreams,
} from "./ratelimit";
import { setStaleTimeout } from "./stale";
import type {
  IridConfig,
  IridRender,
  IridReady,
  OpAttr,
  OpMutate,
  OpText,
  OpWire,
} from "../protocol";

const PROP_ATTRS: Record<string, boolean> = {
  value: true,
  disabled: true,
  checked: true,
  innerHTML: true,
};

const wireRegistered = new Set<string>(); // `${channel}` keys

function applyConfig(msg: IridConfig): void {
  // staleTimeout is materialized (always present); `null` disables the indicator.
  setStaleTimeout(msg.staleTimeout);
}

// A DOM property/attribute write on getElementById(id), gated against the echo's
// channel. Inline (no deferral).
function applyDomAttr(op: OpAttr): void {
  if (isStaleEcho(op.gate, sequences)) return;
  const el = document.getElementById(op.id) as HTMLInputElement | null;
  if (!el) return;
  // Cursor-preservation no-op skip — setting el.value to its current string
  // would reset the cursor on a focused input, so short-circuit identical writes.
  if (
    op.attr === "value" &&
    document.activeElement === el &&
    el.value === op.value
  ) {
    return;
  }
  if (PROP_ATTRS[op.attr]) {
    (el as unknown as Record<string, unknown>)[op.attr] = op.value;
  } else if (op.value === false || op.value === null) {
    el.removeAttribute(op.attr);
  } else if (op.attr === "textContent") {
    el.textContent = op.value as string;
  } else {
    el.setAttribute(op.attr, op.value as string);
  }
}

// Text replacement inside a comment-anchor range. No gate — a text echo is always
// programmatic and applies unconditionally.
function applyText(op: OpText): void {
  const a = lookupAnchors(op.id);
  if (!a) return;
  const parent = a.start.parentNode!;
  let n: Node | null = a.start.nextSibling;
  while (n && n !== a.end) {
    const next: Node | null = n.nextSibling;
    if (n.nodeType === 1) Shiny.unbindAll!(n as Element);
    parent.removeChild(n);
    n = next;
  }
  // `value` is a string; "" is the canonical "clear the range" signal.
  if (op.value !== "") {
    parent.insertBefore(document.createTextNode(op.value), a.end);
  }
}

// Deliver a widget's accumulated, gate-checked prop map to its update() hook (or
// buffer it if async construction is still in flight). The map carries every
// `target="widget"` op for this id from the render pass — one update() call, one
// redraw. Gates were already checked per op during accumulation.
function applyWidgetValues(id: string, values: Record<string, unknown>): void {
  const w = widgets[id];
  if (!w) return; // no widget registered (defense in depth; init precedes attr)
  if (w.handle) {
    if (typeof w.handle.update === "function") w.handle.update(values);
  } else {
    // Async construction still in flight — buffer, coalescing by key.
    w.pending = Object.assign(w.pending || {}, values);
  }
}

function applyMutate(op: OpMutate): void {
  const a = lookupAnchors(op.id);
  if (!a) return;
  const parent = a.start.parentNode!;

  // Each command-part is always present (possibly empty) — forEach over `[]`
  // is a no-op, so no presence guards are needed.

  // 1. Remove children — each child is itself an anchored range.
  op.removes.forEach((childId) => {
    const child = anchors.get(childId);
    if (!child) return;
    const detached = detachRange(child.start, child.end);
    unregisterAnchorsIn(detached);
  });

  // 2. Insert new children (parsed in the container's parent context).
  op.inserts.forEach((html) => {
    const fragment = parseFragment(html, parent);
    indexAnchors(fragment);
    parent.insertBefore(fragment, a.end);
  });

  // 3. Reorder children — lift each child's range into a fragment and reinsert
  // before the container's end anchor (preserves element identity + anchors).
  op.order.forEach((childId) => {
    const child = anchors.get(childId);
    if (!child) return;
    const frag = document.createDocumentFragment();
    let node: Node | null = child.start;
    while (node && node !== child.end) {
      const next: Node | null = node.nextSibling;
      frag.appendChild(node);
      node = next;
    }
    frag.appendChild(child.end);
    parent.insertBefore(frag, a.end);
  });
}

function applyWire(op: OpWire): void {
  // Key on the (namespaced) channel — unique per id/event.
  const key = op.channel;
  if (wireRegistered.has(key)) return;
  // DOM events need the element to exist for addEventListener; widget events
  // bypass that step.
  const el = document.getElementById(op.id);
  if (op.source !== "widget" && !el) return;
  wireRegistered.add(key);
  if (op.source === "dom" && op.clientOnly) {
    // No server handler — apply DOM flags only (no dispatch), no managed state.
    attachListener(el!, op);
    return;
  }
  if (op.timing.mode === "throttle") {
    setupThrottle(el, op, op.timing.ms, op.timing.leading);
  } else if (op.timing.mode === "debounce") {
    setupDebounce(el, op, op.timing.ms);
  } else {
    setupImmediate(el, op);
  }
  // Index widget streams by the {id}:{event} pair a factory resolves against
  // (prop write-backs and events share this namespace; a widget can't reuse a
  // name across the two, so the pair is unique).
  if (op.source === "widget") {
    widgetStreams[`${op.id}:${op.event}`] = managed[op.channel];
  }
}

function applyReady(msg: IridReady): void {
  window.__iridReady = true;
  // Wire `output` is already `name | null` — the public detail shares the shape.
  document.dispatchEvent(
    new CustomEvent("irid:ready", { detail: { id: msg.output } }),
  );
}

// Apply one flush's render: dispatch each op in emission order (apply order),
// landing every change in one synchronous pass (one paint). `target="widget"`
// attrs are accumulated per id and flushed once after the pass, so an atomic-
// render widget redraws once and the deferral lets the widget's `widget-init`
// (earlier in the list) run first. A single `bindAll` runs at the end to
// initialize any new Shiny outputs introduced by mutates.
function applyRender(msg: IridRender): void {
  const widgetAcc: Record<string, Record<string, unknown>> = {};
  let sawMutate = false;
  let mutateParent: Element | null = null;

  msg.ops.forEach((op) => {
    switch (op.kind) {
      case "mutate":
        applyMutate(op);
        sawMutate = true;
        // Remember a parent to bind after the pass; document.body covers all.
        if (!mutateParent) {
          const a = lookupAnchors(op.id);
          if (a) mutateParent = a.start.parentNode as Element;
        }
        break;
      case "wire":
        applyWire(op);
        break;
      case "widget-init":
        handleWidgetInit(op);
        break;
      case "text":
        applyText(op);
        break;
      case "attr":
        if (op.target === "dom") {
          applyDomAttr(op);
        } else if (!isStaleEcho(op.gate, sequences)) {
          // target === "widget" — accumulate, gate-checked per op.
          (widgetAcc[op.id] = widgetAcc[op.id] || {})[op.attr] = op.value;
        }
        break;
    }
  });

  // Deliver each widget's coalesced prop map once, after every op (so a
  // widget-init earlier in the list has run).
  for (const id in widgetAcc) applyWidgetValues(id, widgetAcc[id]);

  // One bindAll after the pass (replacing the per-mutate setTimeout), deferred so
  // Shiny finishes processing the flush's messages first.
  if (sawMutate) {
    const root = mutateParent;
    setTimeout(() => {
      Shiny.bindAll!((root || document.body) as Element);
    }, 0);
  }
}

export function registerHandlers(): void {
  Shiny.addCustomMessageHandler("irid-config", applyConfig);

  // One flush's render — an ordered op list applied in one synchronous pass.
  Shiny.addCustomMessageHandler("irid-render", applyRender);

  // Readiness lifecycle. Sent by the server after a mount's render (so its
  // listeners are attached) and after its server observers exist; WebSocket
  // ordering means that when this lands, the mount is fully wired. We surface it
  // two ways: a public `irid:ready` DOM event app authors can hook (focus an
  // input, hide a splash, start a tour…), and the `window.__iridReady` flag as
  // the "missed the event" escape hatch. The e2e harness waits on the flag.
  Shiny.addCustomMessageHandler("irid-ready", applyReady);
}

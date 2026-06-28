// The Shiny custom-message handlers that drive the client: irid-config,
// irid-attr, irid-mutate, irid-wire, irid-widget-init, irid-ready.

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
  attachClientOnlyListener,
  managed,
  setupDebounce,
  setupImmediate,
  setupThrottle,
  widgetStreams,
} from "./ratelimit";
import { setStaleTimeout } from "./stale";
import type {
  IridAttrMessage,
  IridConfigMessage,
  IridWireEntry,
  IridMutateMessage,
  IridReadyMessage,
  IridWidgetInitMessage,
} from "../protocol";

const PROP_ATTRS: Record<string, boolean> = {
  value: true,
  disabled: true,
  checked: true,
  innerHTML: true,
};

const wireRegistered = new Set<string>(); // `${channel}` keys

export function registerHandlers(): void {
  Shiny.addCustomMessageHandler("irid-config", (msg: IridConfigMessage) => {
    // staleTimeout is materialized (always present); `null` disables the indicator.
    setStaleTimeout(msg.staleTimeout);
  });

  Shiny.addCustomMessageHandler("irid-attr", (msg: IridAttrMessage) => {
    if (msg.target === "widget") {
      // Route to the widget's update hook. Skip if no widget is registered for
      // this id (defense in depth; mount sends init before any attr).
      const w = widgets[msg.id];
      if (!w) return;
      // `values` is a {attr -> value} map. The gate is PER KEY (a batch can carry
      // props from different channels), via valueGates. A key with no valueGates
      // entry (undefined gate) is programmatic and always applies, so an empty
      // `{}` keeps every key — no presence guard needed.
      const kept: Record<string, unknown> = {};
      let any = false;
      for (const k in msg.values) {
        if (isStaleEcho(msg.valueGates[k], sequences)) continue;
        kept[k] = msg.values[k];
        any = true;
      }
      if (!any) return; // every key gated out — nothing to apply
      const values = kept;
      if (w.handle) {
        if (typeof w.handle.update === "function") w.handle.update(values);
      } else {
        // Async construction still in flight — buffer, coalescing by key.
        w.pending = Object.assign(w.pending || {}, values);
      }
      return;
    }

    if (msg.target === "text") {
      // No gate — a text echo is always programmatic and applies unconditionally.
      const a = lookupAnchors(msg.id);
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
      if (msg.value !== "") {
        parent.insertBefore(document.createTextNode(msg.value), a.end);
      }
      return;
    }

    // target === 'dom' — single-channel stale-echo gate.
    if (isStaleEcho(msg.gate, sequences)) return;
    const el = document.getElementById(msg.id) as HTMLInputElement | null;
    if (!el) return;
    // Cursor-preservation no-op skip — setting el.value to its current string
    // would reset the cursor on a focused input, so short-circuit identical writes.
    if (
      msg.attr === "value" &&
      document.activeElement === el &&
      el.value === msg.value
    ) {
      return;
    }
    if (PROP_ATTRS[msg.attr]) {
      (el as unknown as Record<string, unknown>)[msg.attr] = msg.value;
    } else if (msg.value === false || msg.value === null) {
      el.removeAttribute(msg.attr);
    } else if (msg.attr === "textContent") {
      el.textContent = msg.value as string;
    } else {
      el.setAttribute(msg.attr, msg.value as string);
    }
  });

  Shiny.addCustomMessageHandler("irid-mutate", (msg: IridMutateMessage) => {
    const a = lookupAnchors(msg.id);
    if (!a) return;
    const parent = a.start.parentNode!;

    // Each command-part is always present (possibly empty) — forEach over `[]`
    // is a no-op, so no presence guards are needed.

    // 1. Remove children — each child is itself an anchored range.
    msg.removes.forEach((childId) => {
      const child = anchors.get(childId);
      if (!child) return;
      const detached = detachRange(child.start, child.end);
      unregisterAnchorsIn(detached);
    });

    // 2. Insert new children (parsed in the container's parent context).
    msg.inserts.forEach((html) => {
      const fragment = parseFragment(html, parent);
      indexAnchors(fragment);
      parent.insertBefore(fragment, a.end);
    });

    // 3. Reorder children — lift each child's range into a fragment and reinsert
    // before the container's end anchor (preserves element identity + anchors).
    msg.order.forEach((childId) => {
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

    // Defer bindAll so Shiny finishes processing all messages in the flush.
    setTimeout(() => {
      Shiny.bindAll!(parent as Element);
    }, 0);
  });

  Shiny.addCustomMessageHandler("irid-wire", (msgs: IridWireEntry[]) => {
    msgs.forEach((msg) => {
      // Key on the (namespaced) channel — unique per id/event/kind.
      const key = msg.channel;
      if (wireRegistered.has(key)) return;
      // DOM events need the element to exist for addEventListener; widget events
      // bypass that step.
      const el = document.getElementById(msg.id);
      if (msg.source !== "widget" && !el) return;
      wireRegistered.add(key);
      if (msg.source === "dom" && msg.clientOnly) {
        // No server handler — just apply DOM flags, no managed state.
        attachClientOnlyListener(el!, msg);
        return;
      }
      if (msg.timing.mode === "throttle") {
        setupThrottle(el, msg, msg.timing.ms, msg.timing.leading);
      } else if (msg.timing.mode === "debounce") {
        setupDebounce(el, msg, msg.timing.ms);
      } else {
        setupImmediate(el, msg);
      }
      // Index widget streams by the {kind}:{id}:{event} triple a factory resolves.
      if (msg.source === "widget") {
        widgetStreams[`${msg.kind}:${msg.id}:${msg.event}`] =
          managed[msg.channel];
      }
    });
  });

  Shiny.addCustomMessageHandler(
    "irid-widget-init",
    (msg: IridWidgetInitMessage) => {
      handleWidgetInit(msg);
    },
  );

  // Readiness lifecycle. Sent by the server after a mount's `irid-wire` (so its
  // listeners are attached) and after its server observers exist; WebSocket
  // ordering means that when this lands, the mount is fully wired. We surface it
  // two ways: a public `irid:ready` DOM event app authors can hook (focus an
  // input, hide a splash, start a tour…), and the `window.__iridReady` flag as
  // the "missed the event" escape hatch. The e2e harness waits on the flag.
  Shiny.addCustomMessageHandler("irid-ready", (msg: IridReadyMessage) => {
    window.__iridReady = true;
    // Wire `output` is optional/omitted; the public DOM detail uses null.
    document.dispatchEvent(
      new CustomEvent("irid:ready", { detail: { id: msg?.output ?? null } }),
    );
  });
}

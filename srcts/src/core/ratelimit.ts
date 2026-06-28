// Client->server event transport: per-(element,event) managed streams with
// throttle / debounce / immediate timing, optional server-idle backpressure
// (coalesce), and a per-element FIFO ordering queue so an immediate event can't
// overtake a still-debouncing one on the same element.
//
// Shiny dispatches shiny:idle as a jQuery event (see stale.ts), so the idle
// listener uses $(document).one(...).

import { onEventSent } from "./stale";
import { attachPayloadMeta, buildPayload } from "./payload";
import type {
  DomOpts,
  IridClientEvent,
  IridWireDom,
  IridWire,
} from "../protocol";

export interface ManagedStream {
  id: string;
  inputId: string;
  // The buffered payload: the `{ id, seq, data }` envelope awaiting send, or null
  // for an empty slot (before anything is buffered, and after a flush). The
  // timing/queue machinery treats it as opaque — it buffers, coalesces, and orders
  // without reading the fields — but the slot keeps the full envelope type so the
  // rest of the runtime keeps the `id`/`seq`/`data` guarantee.
  payload: IridClientEvent | null;
  serverBusy: boolean;
  coalesce: boolean;
  leading?: boolean;
  timerRunning?: boolean;
  timerReady?: boolean;
  timerId?: ReturnType<typeof setTimeout> | null;
  // Ordering-queue slot.
  qPayload: IridClientEvent | null;
  qReady: boolean;
  maybeSend: () => void;
  dispatch: (payload: IridClientEvent) => void;
  qFlush: () => void;
}

export const managed: Record<string, ManagedStream> = {}; // inputId -> stream
// Widget client->server streams indexed by the `{id}:{event}` pair a factory's
// sendEvent/setProp resolves against (module-namespace-agnostic).
export const widgetStreams: Record<string, ManagedStream> = {};
const elementQueues: Record<string, ManagedStream[]> = {}; // elementId -> pending
let idleListenerActive = false;

function sendPayload(inputId: string, payload: IridClientEvent): void {
  Shiny.setInputValue!(inputId, payload, { priority: "event" });
  onEventSent();
}

function onShinyIdle(): void {
  idleListenerActive = false;
  let anySent = false;
  for (const inputId in managed) {
    const s = managed[inputId];
    if (s.serverBusy) {
      s.serverBusy = false;
      if (s.maybeSend) s.maybeSend();
      if (s.serverBusy) anySent = true;
    }
  }
  if (anySent) {
    $(document).one("shiny:idle", onShinyIdle);
    idleListenerActive = true;
  }
}

function ensureIdleListener(): void {
  if (!idleListenerActive) {
    $(document).one("shiny:idle", onShinyIdle);
    idleListenerActive = true;
  }
}

// --- Per-element ordered send queue ---------------------------------------

function queueJoin(s: ManagedStream): void {
  const q = elementQueues[s.id] || (elementQueues[s.id] = []);
  if (q.indexOf(s) === -1) q.push(s);
}

// Mark `s` ready to send `payload` (may be null), then drain its element.
function queueReady(s: ManagedStream, payload: IridClientEvent | null): void {
  s.qPayload = payload;
  s.qReady = true;
  queueJoin(s);
  drainQueue(s.id);
}

function drainQueue(elId: string): void {
  const q = elementQueues[elId];
  if (!q) return;
  while (q.length) {
    const head = q[0];
    if (!head.qReady) {
      let laterReady = false;
      for (let i = 1; i < q.length; i++) {
        if (q[i].qReady) {
          laterReady = true;
          break;
        }
      }
      if (!laterReady) break; // head still legitimately waiting; stop
      head.qFlush(); // preempt: cancel timer, surface its buffer
    }
    q.shift();
    const p = head.qPayload;
    head.qPayload = null;
    head.qReady = false;
    // Null guard: a slot claimed with no payload is dropped, not sent empty.
    if (p !== null && p !== undefined) {
      sendPayload(head.inputId, p);
      if (head.coalesce) {
        head.serverBusy = true;
        ensureIdleListener();
      }
    }
  }
}

// --- DOM listeners --------------------------------------------------------

// Compile a `wire_dom_opts(filter = ...)` expression into a predicate over the
// DOM event `e`, or null when no filter is set.
function compileFilter(opts: DomOpts): ((e: Event) => boolean) | null {
  if (!opts.filter) return null;
  try {
    return new Function("e", "return (" + opts.filter + ");") as (
      e: Event,
    ) => boolean;
  } catch (err) {
    console.error("irid: invalid event filter expression:", opts.filter, err);
    return null;
  }
}

// Radios only fire `change` on the newly-checked element in practice, but gate
// defensively so a stray deselect-change can't write a stale value.
function shouldSkip(el: HTMLElement, eventName: string): boolean {
  const input = el as HTMLInputElement;
  return (
    eventName === "change" &&
    el.tagName === "INPUT" &&
    input.type === "radio" &&
    !input.checked
  );
}

// Attach the DOM listener: apply the wire's `dom_opts` flags (preventDefault /
// stopPropagation, under the capture/passive/filter options), then dispatch the
// payload. Omitting `dispatch` is a config-only wire (dom_opts, no server handler):
// the flags are applied client-side and the event never round-trips.
export function attachListener(
  el: HTMLElement,
  msg: IridWireDom,
  dispatch?: (payload: IridClientEvent) => void,
): void {
  const opts = msg.domOpts;
  const filter = compileFilter(opts);
  el.addEventListener(
    msg.event,
    (e) => {
      if (shouldSkip(el, msg.event)) return;
      if (filter && !filter(e)) return;
      if (opts.preventDefault) e.preventDefault();
      if (opts.stopPropagation) e.stopPropagation();
      dispatch?.(buildPayload(e, el, msg.id, msg.channel));
    },
    { capture: opts.capture, passive: opts.passive },
  );
}

// --- Stream factories -----------------------------------------------------

export function setupThrottle(
  el: HTMLElement | null,
  msg: IridWire,
  ms: number,
  leading: boolean,
): ManagedStream {
  const s: ManagedStream = {
    id: msg.id,
    inputId: msg.channel,
    payload: null,
    timerRunning: false,
    timerReady: false,
    serverBusy: false,
    coalesce: msg.coalesce,
    leading,
    qPayload: null,
    qReady: false,
    maybeSend: () => {},
    dispatch: () => {},
    qFlush: () => {},
  };

  function startCooldown(): void {
    s.timerRunning = true;
    setTimeout(() => {
      s.timerRunning = false;
      s.timerReady = true;
      s.maybeSend();
    }, ms);
  }

  s.maybeSend = () => {
    if (s.coalesce && s.serverBusy) return;
    if (!s.timerReady) return;
    if (s.payload === null) return;
    const p = s.payload;
    s.payload = null;
    s.timerReady = false;
    queueReady(s, p);
    startCooldown();
  };

  s.dispatch = (payload) => {
    s.payload = payload;
    queueJoin(s); // claim slot at DOM-event time
    if (s.timerRunning) return;
    if (s.leading && !(s.coalesce && s.serverBusy)) {
      // Fire immediately, start cooldown timer.
      const p = s.payload;
      s.payload = null;
      queueReady(s, p);
      startCooldown();
    } else {
      // Start timer, send when it fires.
      startCooldown();
    }
  };

  // Preempt: the leading edge already fired; surface the trailing buffer.
  s.qFlush = () => {
    s.qPayload = s.payload;
    s.payload = null;
    s.timerReady = false;
    s.qReady = true;
  };

  managed[msg.channel] = s;
  if (msg.source !== "widget" && el) attachListener(el, msg, s.dispatch);
  return s;
}

export function setupDebounce(
  el: HTMLElement | null,
  msg: IridWire,
  ms: number,
): ManagedStream {
  const s: ManagedStream = {
    id: msg.id,
    inputId: msg.channel,
    payload: null,
    timerId: null,
    timerReady: false,
    serverBusy: false,
    coalesce: msg.coalesce,
    qPayload: null,
    qReady: false,
    maybeSend: () => {},
    dispatch: () => {},
    qFlush: () => {},
  };

  s.maybeSend = () => {
    if (s.coalesce && s.serverBusy) return;
    if (!s.timerReady) return;
    if (s.payload === null) return;
    const p = s.payload;
    s.payload = null;
    s.timerReady = false;
    queueReady(s, p);
  };

  s.dispatch = (payload) => {
    s.payload = payload;
    s.timerReady = false;
    queueJoin(s); // claim slot at DOM-event time
    if (s.timerId !== null && s.timerId !== undefined) clearTimeout(s.timerId);
    s.timerId = setTimeout(() => {
      s.timerId = null;
      s.timerReady = true;
      s.maybeSend();
    }, ms);
  };

  // Preempt: a later sibling is ready and we're the head. Cancel the timer and
  // surface the buffered payload (null -> dropped by the drain).
  s.qFlush = () => {
    if (s.timerId !== null && s.timerId !== undefined) {
      clearTimeout(s.timerId);
      s.timerId = null;
    }
    s.timerReady = false;
    s.qPayload = s.payload;
    s.payload = null;
    s.qReady = true;
  };

  managed[msg.channel] = s;
  if (msg.source !== "widget" && el) attachListener(el, msg, s.dispatch);
  return s;
}

export function setupImmediate(
  el: HTMLElement | null,
  msg: IridWire,
): ManagedStream {
  // All immediate streams route through the element queue so a plain immediate
  // event can preemptively flush a sibling debounced stream before sending.
  const s: ManagedStream = {
    id: msg.id,
    inputId: msg.channel,
    payload: null,
    serverBusy: false,
    coalesce: msg.coalesce,
    qPayload: null,
    qReady: false,
    maybeSend: () => {},
    dispatch: () => {},
    qFlush: () => {},
  };

  s.maybeSend = () => {
    if (s.coalesce && s.serverBusy) return;
    if (s.payload === null) return;
    const p = s.payload;
    s.payload = null;
    queueReady(s, p);
  };

  s.dispatch = (payload) => {
    s.payload = payload;
    queueJoin(s); // claim slot at DOM-event time
    s.maybeSend();
  };

  // Immediate streams are ready the instant they buffer, so a preempt only
  // happens in a race; surface whatever is buffered.
  s.qFlush = () => {
    s.qPayload = s.payload;
    s.payload = null;
    s.qReady = true;
  };

  managed[msg.channel] = s;
  if (msg.source !== "widget" && el) attachListener(el, msg, s.dispatch);
  return s;
}

// --- Widget push helpers --------------------------------------------------

// Push a payload through a managed stream `s`. Silent no-op if `s` is missing —
// widget JS can register events/props unconditionally and only the ones with an
// R-side handler resolve to a stream.
export function pushManaged(
  s: ManagedStream | undefined,
  id: string,
  payload?: Record<string, unknown>,
): void {
  if (!s) return;
  const p = attachPayloadMeta(Object.assign({}, payload || {}), id, s.inputId);
  s.dispatch(p);
}

/** `sendEvent(event, payload)` — a widget notification. */
export function sendWidgetEvent(
  id: string,
  event: string,
  payload?: Record<string, unknown>,
): void {
  pushManaged(widgetStreams[id + ":" + event], id, payload || {});
}

/** `setProp(key, value)` — the client->server half of a two-way prop. */
export function setWidgetProp(id: string, key: string, value: unknown): void {
  pushManaged(widgetStreams[id + ":" + key], id, { value });
}

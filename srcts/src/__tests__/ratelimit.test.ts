import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// stale.ts touches `document` and jQuery `$` at import time; the transport only
// needs its onEventSent hook, so stub the module (node env, no DOM).
vi.mock("../core/stale", () => ({ onEventSent: () => {} }));

import {
  managed,
  setupDebounce,
  setupImmediate,
  setupThrottle,
} from "../core/ratelimit";
import type { IridClientEvent, OpWireWidget } from "../protocol";

interface Sent {
  inputId: string;
  payload: unknown;
}
let sent: Sent[];

// Build a real client->server envelope. The timing/queue logic never reads the
// fields, so `data` carries whatever the case under test wants to track and `seq`
// is a fixed stand-in (the per-channel counter lives in the DOM path, bypassed
// here by calling `dispatch` directly).
function makeEvent(data: Record<string, unknown>): IridClientEvent {
  return { id: "el", seq: 0, data };
}

beforeEach(() => {
  vi.useFakeTimers();
  sent = [];
  (globalThis as unknown as { Shiny: unknown }).Shiny = {
    setInputValue: (inputId: string, payload: unknown) =>
      sent.push({ inputId, payload }),
  };
  for (const k in managed) delete managed[k];
});

afterEach(() => {
  vi.useRealTimers();
});

// source:"widget" so no DOM listener is attached (el can be null); coalesce:false
// so the server-idle path ($(document).one) is never hit. Timing (ms/leading) is
// passed explicitly to each setup factory, so the carrier `timing` here is inert.
function msg(over: Partial<OpWireWidget>): OpWireWidget {
  return {
    kind: "wire",
    id: "el",
    event: "input",
    channel: "in",
    source: "widget",
    timing: { mode: "immediate" },
    coalesce: false,
    ...over,
  };
}

describe("debounce", () => {
  it("sends once after the window, with the latest payload", () => {
    const s = setupDebounce(null, msg({ id: "d", channel: "din" }), 200);
    s.dispatch(makeEvent({ value: "a" }));
    vi.advanceTimersByTime(100);
    s.dispatch(makeEvent({ value: "b" })); // resets the window
    vi.advanceTimersByTime(199);
    expect(sent).toHaveLength(0);
    vi.advanceTimersByTime(1);
    expect(sent).toEqual([
      { inputId: "din", payload: makeEvent({ value: "b" }) },
    ]);
  });
});

describe("throttle (leading)", () => {
  it("fires immediately, then a trailing event after the window", () => {
    const s = setupThrottle(null, msg({ id: "t", channel: "tin" }), 100, true);
    s.dispatch(makeEvent({ v: 1 }));
    // leading edge
    expect(sent).toEqual([{ inputId: "tin", payload: makeEvent({ v: 1 }) }]);
    s.dispatch(makeEvent({ v: 2 })); // during cooldown -> buffered as trailing
    expect(sent).toHaveLength(1);
    vi.advanceTimersByTime(100);
    expect(sent).toEqual([
      { inputId: "tin", payload: makeEvent({ v: 1 }) },
      { inputId: "tin", payload: makeEvent({ v: 2 }) },
    ]);
  });
});

describe("per-element ordering queue", () => {
  it("an immediate event preempts a still-debouncing one on the same element", () => {
    // The canonical bug: typing (debounced input) then Enter (immediate keydown)
    // on the same element — the Enter must not overtake the buffered input.
    const d = setupDebounce(null, msg({ id: "shared", channel: "d" }), 200);
    const i = setupImmediate(null, msg({ id: "shared", channel: "i" }));
    d.dispatch(makeEvent({ value: "typed" })); // joins queue, timer running, not yet sent
    expect(sent).toHaveLength(0);
    i.dispatch(makeEvent({ key: "Enter" })); // ready now -> drains, preempting the debounce
    expect(sent).toEqual([
      { inputId: "d", payload: makeEvent({ value: "typed" }) },
      { inputId: "i", payload: makeEvent({ key: "Enter" }) },
    ]);
  });

  it("does not couple streams on different elements", () => {
    const a = setupDebounce(null, msg({ id: "elA", channel: "a" }), 200);
    const b = setupImmediate(null, msg({ id: "elB", channel: "b" }));
    a.dispatch(makeEvent({ value: "x" }));
    b.dispatch(makeEvent({ key: "y" })); // different element: sends without touching a
    expect(sent).toEqual([{ inputId: "b", payload: makeEvent({ key: "y" }) }]);
    vi.advanceTimersByTime(200);
    expect(sent).toEqual([
      { inputId: "b", payload: makeEvent({ key: "y" }) },
      { inputId: "a", payload: makeEvent({ value: "x" }) },
    ]);
  });
});

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
import type { IridWidgetEvent } from "../protocol";

interface Sent {
  inputId: string;
  payload: unknown;
}
let sent: Sent[];

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
function msg(over: Partial<IridWidgetEvent>): IridWidgetEvent {
  return {
    id: "el",
    event: "input",
    inputId: "in",
    source: "widget",
    kind: "event",
    timing: { mode: "immediate" },
    coalesce: false,
    ...over,
  };
}

describe("debounce", () => {
  it("sends once after the window, with the latest payload", () => {
    const s = setupDebounce(null, msg({ id: "d", inputId: "din" }), 200);
    s.dispatch({ value: "a" });
    vi.advanceTimersByTime(100);
    s.dispatch({ value: "b" }); // resets the window
    vi.advanceTimersByTime(199);
    expect(sent).toHaveLength(0);
    vi.advanceTimersByTime(1);
    expect(sent).toEqual([{ inputId: "din", payload: { value: "b" } }]);
  });
});

describe("throttle (leading)", () => {
  it("fires immediately, then a trailing event after the window", () => {
    const s = setupThrottle(null, msg({ id: "t", inputId: "tin" }), 100, true);
    s.dispatch({ v: 1 });
    expect(sent).toEqual([{ inputId: "tin", payload: { v: 1 } }]); // leading edge
    s.dispatch({ v: 2 }); // during cooldown -> buffered as trailing
    expect(sent).toHaveLength(1);
    vi.advanceTimersByTime(100);
    expect(sent).toEqual([
      { inputId: "tin", payload: { v: 1 } },
      { inputId: "tin", payload: { v: 2 } },
    ]);
  });
});

describe("per-element ordering queue", () => {
  it("an immediate event preempts a still-debouncing one on the same element", () => {
    // The canonical bug: typing (debounced input) then Enter (immediate keydown)
    // on the same element — the Enter must not overtake the buffered input.
    const d = setupDebounce(null, msg({ id: "shared", inputId: "d" }), 200);
    const i = setupImmediate(null, msg({ id: "shared", inputId: "i" }));
    d.dispatch({ value: "typed" }); // joins queue, timer running, not yet sent
    expect(sent).toHaveLength(0);
    i.dispatch({ key: "Enter" }); // ready now -> drains, preempting the debounce
    expect(sent).toEqual([
      { inputId: "d", payload: { value: "typed" } },
      { inputId: "i", payload: { key: "Enter" } },
    ]);
  });

  it("does not couple streams on different elements", () => {
    const a = setupDebounce(null, msg({ id: "elA", inputId: "a" }), 200);
    const b = setupImmediate(null, msg({ id: "elB", inputId: "b" }));
    a.dispatch({ value: "x" });
    b.dispatch({ key: "y" }); // different element: sends without touching a
    expect(sent).toEqual([{ inputId: "b", payload: { key: "y" } }]);
    vi.advanceTimersByTime(200);
    expect(sent).toEqual([
      { inputId: "b", payload: { key: "y" } },
      { inputId: "a", payload: { value: "x" } },
    ]);
  });
});

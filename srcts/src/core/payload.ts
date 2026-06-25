// Client->server payload construction: the irid envelope (stable id, per-event
// nonce, per-channel sequence) plus DOM-event field extraction.

import { nextSequence, sequences } from "./seq";
import type { EventPayload, PayloadMeta } from "../protocol";

/**
 * Attach the irid envelope to a payload: stable element id, a per-event nonce,
 * and a per-CHANNEL monotonic sequence (`channel` is the inputId it's sent on).
 * Shared between DOM events and widget events so both produce identical shapes.
 */
export function attachPayloadMeta<T extends Record<string, unknown>>(
  payload: T,
  id: string,
  channel: string,
): T & PayloadMeta {
  const p = payload as T & PayloadMeta;
  p.id = id;
  p.nonce = Math.random();
  p.__irid_seq = nextSequence(sequences, channel);
  return p;
}

/** Build a DOM-event payload from the event + its element, then stamp the envelope. */
export function buildPayload(
  e: Event,
  el: HTMLElement,
  id: string,
  channel: string,
): EventPayload {
  const payload: Record<string, unknown> = {};
  // Extract all primitive-valued properties from the event object.
  for (const key in e) {
    try {
      const val = (e as unknown as Record<string, unknown>)[key];
      if (
        typeof val === "string" ||
        typeof val === "number" ||
        typeof val === "boolean"
      ) {
        payload[key] = val;
      }
    } catch {
      // Some event properties may throw on access; skip them.
    }
  }
  // Element properties (override event props of the same name).
  const input = el as HTMLInputElement;
  payload.value = input.value;
  if (typeof input.valueAsNumber === "number") {
    payload.valueAsNumber = input.valueAsNumber;
  }
  if (typeof input.checked === "boolean") {
    payload.checked = input.checked;
  }
  return attachPayloadMeta(payload, id, channel) as EventPayload;
}

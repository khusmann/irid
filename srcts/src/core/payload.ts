// Client->server payload construction: the irid transport envelope (`{ id, seq,
// data }`) plus DOM-event field extraction. The envelope owns the top level and
// the foreign event data lives under `data`, so irid's bookkeeping never collides
// with DOM/widget-author field names — no prefix needed (the mirror of R's
// `irid_decode_payload`).

import { nextSequence, sequences } from "./seq";
import type { EventPayload } from "../protocol";

/**
 * Wrap the event data in the irid envelope: a stable element `id`, a per-CHANNEL
 * monotonic `seq` (the echo gate; `channel` is the inputId it's sent on), and the
 * foreign event data under `data`. Shared between DOM and widget events.
 */
export function attachPayloadMeta(
  data: Record<string, unknown>,
  id: string,
  channel: string,
): EventPayload {
  return { id, seq: nextSequence(sequences, channel), data };
}

/** Build a DOM-event data object from the event + its element, then wrap it. */
export function buildPayload(
  e: Event,
  el: HTMLElement,
  id: string,
  channel: string,
): EventPayload {
  const data: Record<string, unknown> = {};
  // Extract all primitive-valued properties from the event object.
  for (const key in e) {
    try {
      const val = (e as unknown as Record<string, unknown>)[key];
      if (
        typeof val === "string" ||
        typeof val === "number" ||
        typeof val === "boolean"
      ) {
        data[key] = val;
      }
    } catch {
      // Some event properties may throw on access; skip them.
    }
  }
  // Element properties (override event props of the same name).
  const input = el as HTMLInputElement;
  data.value = input.value;
  if (typeof input.valueAsNumber === "number") {
    data.valueAsNumber = input.valueAsNumber;
  }
  if (typeof input.checked === "boolean") {
    data.checked = input.checked;
  }
  return attachPayloadMeta(data, id, channel);
}

// Per-channel sequence counters + the stale-echo gate (the optimistic-update
// protocol's core decision logic). A "channel" is one client->server stream from
// an element (a DOM event, a widget event, or a widget prop write-back), keyed by
// its send inputId.
//
// The pure functions take `sequences` explicitly so they're unit-testable; the
// runtime threads the shared `sequences` singleton below.

import type { EchoGate } from "../protocol";

export type Sequences = Record<string, number>;

/** Shared runtime counter map: channel (send inputId) -> latest sent sequence. */
export const sequences: Sequences = {};

/**
 * Has the gate's channel counter already moved past the echo's seq? Inert when
 * no gate is present (a programmatic update) or when the counter hasn't advanced
 * beyond the echo. One `EchoGate` shape, called identically from the dom path
 * (`msg.gate`, `EchoGate | null`) and the widget per-key path (`valueGates[k]`,
 * `EchoGate | undefined`) — both "no gate" spellings mean "apply".
 */
export function isStaleEcho(
  gate: EchoGate | null | undefined,
  seqs: Sequences,
): boolean {
  if (!gate) return false;
  const latest = seqs[gate.channel];
  return latest !== undefined && gate.seq < latest;
}

/** Bump the channel's counter and return the new value (mutates `seqs`). */
export function nextSequence(seqs: Sequences, channel: string): number {
  if (!seqs[channel]) seqs[channel] = 0;
  return ++seqs[channel];
}

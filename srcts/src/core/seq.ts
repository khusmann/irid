// Per-channel sequence counters + the stale-echo gate (the optimistic-update
// protocol's core decision logic). A "channel" is one client->server stream from
// an element (a DOM event, a widget event, or a widget prop write-back), keyed by
// its send inputId.
//
// The pure functions take `sequences` explicitly so they're unit-testable; the
// runtime threads the shared `sequences` singleton below.

export type Sequences = Record<string, number>;

/** Shared runtime counter map: channel (send inputId) -> latest sent sequence. */
export const sequences: Sequences = {};

/**
 * Has the channel's counter already moved past this echo's seq? Inert when no
 * sequence/channel is present (programmatic updates) or when the counter hasn't
 * advanced beyond the echo.
 */
export function isStaleEcho(
  seq: number | null | undefined,
  channel: string | null | undefined,
  seqs: Sequences,
): boolean {
  return (
    seq !== undefined &&
    seq !== null &&
    channel !== undefined &&
    channel !== null &&
    seqs[channel] !== undefined &&
    seq < seqs[channel]
  );
}

/** Bump the channel's counter and return the new value (mutates `seqs`). */
export function nextSequence(seqs: Sequences, channel: string): number {
  if (!seqs[channel]) seqs[channel] = 0;
  return ++seqs[channel];
}

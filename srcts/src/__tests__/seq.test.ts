import { describe, expect, it } from "vitest";
import { isStaleEcho, nextSequence, type Sequences } from "../core/seq";

describe("isStaleEcho", () => {
  it("is inert for programmatic updates (no gate)", () => {
    const seqs: Sequences = { ch: 5 };
    expect(isStaleEcho(undefined, seqs)).toBe(false);
  });

  it("is inert when the channel has never been sent on", () => {
    expect(isStaleEcho({ seq: 1, channel: "never" }, {})).toBe(false);
  });

  it("applies a current or future echo (seq >= counter)", () => {
    const seqs: Sequences = { ch: 5 };
    expect(isStaleEcho({ seq: 5, channel: "ch" }, seqs)).toBe(false); // current
    expect(isStaleEcho({ seq: 6, channel: "ch" }, seqs)).toBe(false); // future
  });

  it("drops a stale echo (seq < counter)", () => {
    const seqs: Sequences = { ch: 5 };
    expect(isStaleEcho({ seq: 4, channel: "ch" }, seqs)).toBe(true);
    expect(isStaleEcho({ seq: 0, channel: "ch" }, seqs)).toBe(true);
  });

  it("gates per channel — a sibling channel's counter does not gate", () => {
    const seqs: Sequences = { a: 10, b: 1 };
    // echo for channel b, seq 1: b's counter is 1, not advanced past it
    expect(isStaleEcho({ seq: 1, channel: "b" }, seqs)).toBe(false);
    // a's high counter must not gate b's echo
    expect(isStaleEcho({ seq: 1, channel: "a" }, seqs)).toBe(true);
  });
});

describe("nextSequence", () => {
  it("initializes a channel at 0 and returns 1 on first bump", () => {
    const seqs: Sequences = {};
    expect(nextSequence(seqs, "ch")).toBe(1);
    expect(nextSequence(seqs, "ch")).toBe(2);
    expect(seqs.ch).toBe(2);
  });

  it("counts each channel independently", () => {
    const seqs: Sequences = {};
    expect(nextSequence(seqs, "a")).toBe(1);
    expect(nextSequence(seqs, "b")).toBe(1);
    expect(nextSequence(seqs, "a")).toBe(2);
    expect(seqs).toEqual({ a: 2, b: 1 });
  });

  it("a fresh send makes the prior in-flight echo stale, sibling untouched", () => {
    const seqs: Sequences = {};
    const echoSeq = nextSequence(seqs, "a"); // 1, an in-flight echo's seq
    nextSequence(seqs, "a"); // user produces another event on the same channel
    expect(isStaleEcho({ seq: echoSeq, channel: "a" }, seqs)).toBe(true); // stale
    // a send on a sibling channel never gates channel a's echo
    nextSequence(seqs, "b");
    expect(isStaleEcho({ seq: 2, channel: "a" }, seqs)).toBe(false); // current
  });
});

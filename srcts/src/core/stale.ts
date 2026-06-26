// Stale UI indicator: when the server takes too long to echo after an event, an
// animated bar (irid.css, toggled by the `irid-stale` class on <html>) signals
// that displayed state may be stale. This module owns the show/clear timers and
// the shiny:busy/idle wiring.
//
// NOTE: Shiny dispatches shiny:idle/shiny:busy as jQuery events, NOT native DOM
// events, so these must be registered via $(document).on(...) — addEventListener
// would never fire. (Verified against Shiny 1.11.0; re-confirm on bump.)

let staleTimeout: number | null = null; // ms before showing; null = disabled
let staleShowTimerId: ReturnType<typeof setTimeout> | null = null;
let staleClearTimerId: ReturnType<typeof setTimeout> | null = null;
const STALE_CLEAR_DELAY = 100; // ms after idle before removing the overlay

/** Set from the `irid-config` message. */
export function setStaleTimeout(value: number | null): void {
  staleTimeout = value;
}

export function markStale(): void {
  if (staleClearTimerId !== null) {
    clearTimeout(staleClearTimerId);
    staleClearTimerId = null;
  }
  document.documentElement.classList.add("irid-stale");
}

export function clearStale(): void {
  if (staleShowTimerId !== null) {
    clearTimeout(staleShowTimerId);
    staleShowTimerId = null;
  }
  // Debounce the clear so rapid idle/busy cycles don't flicker.
  if (staleClearTimerId === null) {
    staleClearTimerId = setTimeout(() => {
      staleClearTimerId = null;
      document.documentElement.classList.remove("irid-stale");
    }, STALE_CLEAR_DELAY);
  }
}

export function onEventSent(): void {
  // Cancel any pending clear — we're busy again.
  if (staleClearTimerId !== null) {
    clearTimeout(staleClearTimerId);
    staleClearTimerId = null;
  }
  if (
    staleTimeout !== null &&
    staleShowTimerId === null &&
    !document.documentElement.classList.contains("irid-stale")
  ) {
    staleShowTimerId = setTimeout(markStale, staleTimeout);
  }
}

// Cancel a pending clear if the server becomes busy again (e.g. a reactive chain
// triggers a follow-up flush after the initial idle).
$(document).on("shiny:busy", () => {
  if (staleClearTimerId !== null) {
    clearTimeout(staleClearTimerId);
    staleClearTimerId = null;
  }
});

// Clear stale state when the server finishes processing.
$(document).on("shiny:idle", () => {
  clearStale();
});

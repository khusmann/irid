// irid client runtime entry point. Assembles the public `window.irid` surface,
// performs the initial comment-anchor scan, and registers the Shiny custom-message
// handlers. esbuild bundles this to inst/js/irid.js (IIFE).

import "./stale"; // side effect: installs the shiny:busy / shiny:idle listeners
import { indexAnchors } from "./anchors";
import { defineWidget } from "./widgets";
import { registerHandlers } from "./handlers";
import type { Irid } from "../protocol";

const irid: Irid = { defineWidget };
window.irid = irid;

// Initial scan — comment anchors in the static page must be registered before any
// irid-swap / irid-mutate message arrives.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    indexAnchors(document.body);
  });
} else {
  indexAnchors(document.body);
}

registerHandlers();

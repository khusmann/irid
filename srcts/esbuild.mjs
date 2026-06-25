// Build the two client entry points to browser-ready IIFE bundles, vendored
// into ../inst (the R package's served assets). esbuild only strips types and
// transpiles — `tsc --noEmit` is the actual typecheck (see package.json).
//
// Output (committed; see TESTING.md):
//   ../inst/js/irid.js                      (+ .js.map)
//   ../inst/widgets/plotly/plotly-irid.js   (+ .js.map)
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const root = dirname(fileURLToPath(import.meta.url));
const inst = resolve(root, "..", "inst");

const common = {
  bundle: true,
  format: "iife",
  target: ["es2019"],
  sourcemap: "linked", // external .map + //# sourceMappingURL comment
  logLevel: "info",
};

await Promise.all([
  build({
    ...common,
    entryPoints: [resolve(root, "src/core/index.ts")],
    outfile: resolve(inst, "js/irid.js"),
  }),
  build({
    ...common,
    entryPoints: [resolve(root, "src/widgets/plotly/index.ts")],
    outfile: resolve(inst, "widgets/plotly/plotly-irid.js"),
  }),
]);

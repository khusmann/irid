import { defineConfig } from "vitest/config";

// vitest runs node-env (no jsdom): it covers the pure decision logic + timing
// only. DOM-bound modules (anchors/handlers/stale/widgets) stay e2e-only — see
// "Test scope" in dev/srcts-migration.md.
export default defineConfig({
  test: {
    environment: "node",
    passWithNoTests: true,
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      // Scope to the modules vitest is responsible for — the pure decision logic
      // + timing. The DOM-bound modules (anchors/handlers/index/stale/widgets,
      // plotly/index, payload's DOM reads) are covered by the e2e suite and would
      // otherwise dilute the number to a misleading value (cf. covr not seeing JS
      // on the R side). See "Test scope" in dev/srcts-migration.md.
      include: [
        "src/core/seq.ts",
        "src/core/ratelimit.ts",
        "src/widgets/plotly/pure.ts",
      ],
    },
  },
});

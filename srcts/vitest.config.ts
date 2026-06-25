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
      include: ["src/**/*.ts"],
      exclude: ["src/**/*.test.ts", "src/**/*.d.ts", "src/protocol.ts"],
    },
  },
});

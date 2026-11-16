import { defineConfig } from "vitest/config";

// Tests live in tests/, outside src/, so `npm run build` (tsc + vite) never
// sees them. Everything runs in jsdom: even the "pure" modules touch
// localStorage or document at import time.
export default defineConfig({
  test: {
    environment: "jsdom",
    environmentOptions: { jsdom: { url: "http://localhost/" } },
    include: ["tests/**/*.test.ts"],
    setupFiles: ["tests/setup.ts"],
    css: false,
    testTimeout: 15000,
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      reporter: ["text-summary", "json-summary", "html"],
      reportsDirectory: "coverage",
    },
  },
});

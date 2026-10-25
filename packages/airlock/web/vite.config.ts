import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

const fixturePort = process.env.AIRLOCK_FIXTURE_PORT ?? "5178";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "happy-dom",
    globals: true,
  },
  server: {
    proxy: {
      "/api": {
        target: `http://127.0.0.1:${fixturePort}`,
        changeOrigin: false,
        ws: true,
      },
    },
  },
});

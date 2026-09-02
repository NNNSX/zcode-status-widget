import { defineConfig } from "vite";

export default defineConfig({
  root: ".",
  base: "./",
  build: {
    outDir: "dist/renderer",
    emptyOutDir: true,
  },
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
  },
});

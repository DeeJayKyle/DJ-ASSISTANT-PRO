import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 5173, strictPort: true, host: "127.0.0.1", watch: { ignored: ["**/e2e/.data/**", "**/docs/**", "**/target/**", "**/src-tauri/**", "**/graphify-out/**"] } },
  build: { target: "es2022", sourcemap: false },
  test: { environment: "jsdom", include: ["src/**/*.test.{ts,tsx}"] },
});

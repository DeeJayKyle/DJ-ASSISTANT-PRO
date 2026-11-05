import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/** ONNX Runtime Web points at its WebAssembly file with `new URL(…, import.meta.url)`, which
 * would copy 25 MB into every installer. The Studio always loads it from the installed
 * Pro Stems AI pack instead (env.wasm.wasmPaths), so drop that reference from the bundle. */
const ortWasmFromPack = {
  name: "ort-wasm-from-pack",
  enforce: "pre" as const,
  transform(code: string, id: string) {
    if (!id.includes("onnxruntime-web")) return null;
    return code.replace(/new URL\("ort-wasm[^"]*\.wasm",\s*import\.meta\.url\)\.href/g, '"ort-wasm-from-pack.wasm"');
  },
};

export default defineConfig({
  plugins: [react(), ortWasmFromPack],
  worker: { format: "es", plugins: () => [ortWasmFromPack] },
  clearScreen: false,
  server: { port: 5173, strictPort: true, host: "127.0.0.1", watch: { ignored: ["**/e2e/.data/**", "**/docs/**", "**/target/**", "**/src-tauri/**", "**/graphify-out/**"] } },
  build: { target: "es2022", sourcemap: false },
  test: { environment: "jsdom", include: ["src/**/*.test.{ts,tsx}"] },
});

/// <reference lib="webworker" />
import * as ort from 'onnxruntime-web/webgpu';
import { separateAi, SEG, AI_STEMS } from './audio/aistems';

/**
 * Runs HTDemucs (the Pro Stems AI pack) off the UI thread with ONNX Runtime Web:
 * on the graphics card through WebGPU when available, otherwise on the processor.
 * The model and the runtime's WebAssembly file come from the installed pack.
 */
let session: ort.InferenceSession | null = null;
let device = 'cpu';
let cancel = false;
const post = (m: unknown, t: Transferable[] = []) => (self as unknown as Worker).postMessage(m, t);

async function load(modelUrl: string, wasmUrl: string) {
  if (session) return;
  ort.env.wasm.wasmPaths = { wasm: wasmUrl };
  ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(8, navigator.hardwareConcurrency || 4) : 1;
  const res = await fetch(modelUrl);
  if (!res.ok) throw new Error('The Pro Stems AI pack is not installed (Settings → Packs).');
  const total = Number(res.headers.get('Content-Length')) || 0;
  const reader = res.body!.getReader();
  const parts: Uint8Array[] = [];
  let got = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value); got += value.length;
    post({ type: 'loading', done: got, total });
  }
  const bytes = new Uint8Array(got);
  let o = 0;
  for (const p of parts) { bytes.set(p, o); o += p.length; }
  const gpu = 'gpu' in navigator && !!(await (navigator as unknown as { gpu: { requestAdapter(): Promise<unknown> } }).gpu.requestAdapter().catch(() => null));
  try {
    session = await ort.InferenceSession.create(bytes, { executionProviders: gpu ? ['webgpu', 'wasm'] : ['wasm'], graphOptimizationLevel: 'basic' });
    device = gpu ? 'gpu' : 'cpu';
  } catch (e) {
    if (!gpu) throw e;
    session = await ort.InferenceSession.create(bytes, { executionProviders: ['wasm'], graphOptimizationLevel: 'basic' });
    device = 'cpu';
  }
}

self.onmessage = async (e: MessageEvent) => {
  const m = e.data;
  if (m.type === 'cancel') { cancel = true; return; }
  try {
    await load(m.modelUrl, m.wasmUrl);
    cancel = false;
    const s = session!;
    const run = async (waveform: Float32Array, spec: Float32Array) => {
      const feeds: Record<string, ort.Tensor> = { [s.inputNames[0]]: new ort.Tensor('float32', waveform, [1, 2, SEG]) };
      if (s.inputNames.length > 1) feeds[s.inputNames[1]] = new ort.Tensor('float32', spec, [1, 4, 2048, 336]);
      const r = await s.run(feeds);
      let time: Float32Array | null = null, freq: Float32Array | null = null;
      for (const name of s.outputNames) {
        const t = r[name];
        if (t.dims.length === 4 && t.dims[2] === 2) time = t.data as Float32Array;
        else if (t.dims.length === 5 && t.dims[2] === 4) freq = t.data as Float32Array;
      }
      if (!time) throw new Error('unexpected model output');
      return { freq, time };
    };
    const started = performance.now();
    const out = await separateAi(m.channels, m.sampleRate, run, (done, total) => post({ id: m.id, progress: done / total, device }), () => cancel);
    const bufs = AI_STEMS.flatMap((k) => out[k].map((c) => c.buffer as ArrayBuffer));
    post({ id: m.id, result: { stems: out, device, ms: performance.now() - started } }, bufs);
  } catch (err) {
    post({ id: m.id, error: err instanceof Error ? err.message : String(err) });
  }
};

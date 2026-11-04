import { Deck } from './audio/stretch';

/** Realtime DJ deck in the audio thread: tempo, key and stem gains change while it plays. */
declare const sampleRate: number;
declare function registerProcessor(name: string, ctor: unknown): void;
declare class AudioWorkletProcessor { port: MessagePort; constructor(); }

class DeckProcessor extends AudioWorkletProcessor {
  deck: Deck | null = null;
  srcRate = 44100;
  tick = 0;
  constructor() {
    super();
    this.port.onmessage = (e: MessageEvent) => {
      const m = e.data;
      if (m.type === 'load') {
        this.srcRate = m.sampleRate;
        this.deck = new Deck(m.layers as Float32Array[][]);
        // play back at the context rate: fold the sample-rate difference into the tempo
        this.deck.seek(0);
      } else if (this.deck) {
        if (m.type === 'play') this.deck.playing = true;
        if (m.type === 'pause') this.deck.playing = false;
        if (m.type === 'seek') this.deck.seek(m.sec * this.srcRate);
        if (m.type === 'rate') this.deck.rate = m.rate * (this.srcRate / sampleRate);
        if (m.type === 'pitch') this.deck.pitch = m.pitch * (this.srcRate / sampleRate);
        if (m.type === 'gains') this.deck.gains = m.gains;
      }
    };
  }
  process(_inputs: Float32Array[][], outputs: Float32Array[][]) {
    const out = outputs[0];
    if (!this.deck || out.length < 2) return true;
    this.deck.render(out, out[0].length);
    if (++this.tick % 12 === 0) this.port.postMessage({ type: 'time', sec: this.deck.time(this.srcRate), playing: this.deck.playing, ended: this.deck.pos >= this.deck.length });
    return true;
  }
}
registerProcessor('studio-deck', DeckProcessor);

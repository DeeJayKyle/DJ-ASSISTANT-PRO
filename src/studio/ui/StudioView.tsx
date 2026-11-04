import { useState } from 'react';
import { StudioProvider, type StudioHost } from './host';
import type { SongRef } from '../engine';
import { StemsPage } from './StemsPage';
import { RemixPage } from './RemixPage';
import { DjPage } from './DjPage';
import { SynthLab, DrumLab } from './SoundLab';
import '../studio.css';

export type StudioTab = 'stems' | 'remix' | 'dj' | 'synth' | 'drums';
const TABS: { id: StudioTab; label: string; hint: string }[] = [
  { id: 'stems', label: 'Stems', hint: 'Vocals, drums, bass, melodies · key, tempo, chords · MIDI' },
  { id: 'remix', label: 'Remix', hint: 'Mash up songs and stems, auto-synced' },
  { id: 'dj', label: 'DJ', hint: 'Two decks with auto beat-matching' },
  { id: 'synth', label: 'Synth Lab', hint: 'Make an instrument from words' },
  { id: 'drums', label: 'Drum Lab', hint: 'Make a drum kit from words' },
];

/** The whole studio: one view with tabs, usable in any host app. */
export function StudioView({ host, tab: controlled, onTab, showTabs = true }: { host: StudioHost; tab?: StudioTab; onTab?: (t: StudioTab) => void; showTabs?: boolean }) {
  const [own, setOwn] = useState<StudioTab>(controlled ?? 'stems');
  const tab = onTab && controlled ? controlled : own;
  const setTab = (t: StudioTab) => (onTab ? onTab(t) : setOwn(t));
  const initial = tab;
  const [toRemix, setToRemix] = useState<SongRef | null>(null);
  const [toDeck, setToDeck] = useState<SongRef | null>(null);
  const current = showTabs ? tab : initial;
  return (
    <StudioProvider host={host}>
      <div className="st-root">
        {showTabs && (
          <nav className="st-tabs" role="tablist" aria-label="Studio">
            {TABS.map((t) => (
              <button key={t.id} role="tab" aria-selected={tab === t.id} className={`st-tab${tab === t.id ? ' on' : ''}`} onClick={() => setTab(t.id)} title={t.hint}>{t.label}</button>
            ))}
          </nav>
        )}
        {/* Pages stay mounted so playing decks and loaded remixes survive tab changes. */}
        <div hidden={current !== 'stems'}><StemsPage onSendToRemix={(s) => { setToRemix({ ...s }); setTab('remix'); }} onSendToDeck={(s) => { setToDeck({ ...s }); setTab('dj'); }} /></div>
        <div hidden={current !== 'remix'}><RemixPage incoming={toRemix} active={current === 'remix'} /></div>
        <div hidden={current !== 'dj'}><DjPage incoming={toDeck} /></div>
        <div hidden={current !== 'synth'}><SynthLab active={current === 'synth'} /></div>
        <div hidden={current !== 'drums'}><DrumLab active={current === 'drums'} /></div>
      </div>
    </StudioProvider>
  );
}

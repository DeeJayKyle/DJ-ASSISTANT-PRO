const PLANNED: { title: string; body: string }[] = [
  { title: "Metadata suggestions", body: "MusicBrainz lookups and optional AcoustID fingerprints, shown as suggestions with source and confidence for you to accept, edit or reject. Opt-in." },
  { title: "Audio analysis", body: "Local BPM (with half/double-time warnings), key, energy, loudness, silence and clipping estimates — always editable, with method and version recorded." },
  { title: "Discovery", body: "Find music that fits a crate, gaps in your collection and related artists, with every recommendation explained and sourced." },
  { title: "Set studio", body: "Plan a set by event, duration and energy journey; get an editable running order with alternatives. Never presented as guaranteed to mix." },
  { title: "Gig mode and gig packs", body: "Offline essentials during a gig; copy approved tracks to a drive with verification, a manifest and a missing-file report." },
  { title: "Safe file changes", body: "Tag edits and renames only with an exact preview, conflict checks, verified backups, explicit approval and a change log with rollback." },
  { title: "Serato awareness", body: "Read-only import of crates or history, tested against a disposable library copy first. Writing to Serato is not planned." },
  { title: "Personal files", body: "A separate, opt-in module to index and search chosen document folders locally." },
];

export function RoadmapView() {
  return (
    <>
      <div className="view-head">
        <div className="grow">
          <h1>Coming later</h1>
          <div className="sub">These features are planned and are not available in this version. Nothing here runs yet.</div>
        </div>
      </div>
      <div className="view-body">
        <div className="planned">
          {PLANNED.map((p) => (
            <div key={p.title} className="panel">
              <div className="row" style={{ marginBottom: 6 }}>
                <h3 style={{ flex: 1 }}>{p.title}</h3>
                <span className="badge q-unknown">Planned</span>
              </div>
              <p className="muted small">{p.body}</p>
            </div>
          ))}
        </div>
      </div>
    </>
  );
}

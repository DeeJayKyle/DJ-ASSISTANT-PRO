import { useEffect, useState } from "react";
import { api } from "../api";
import type { Crate, FieldInfo, RuleSet, TrackRow } from "../types";
import { cleanRuleSet, emptyRuleSet } from "../lib/rules";
import { plural, text } from "../lib/format";
import { RuleBuilder } from "./RuleBuilder";
import { ColorPicker, Dialog, useDebounced } from "./ui";

export function CrateDialog({
  initial,
  initialRules,
  fields,
  onClose,
  onSaved,
  onDeleted,
}: {
  initial: Crate | null;
  initialRules?: RuleSet | null;
  fields: FieldInfo[];
  onClose: () => void;
  onSaved: (c: Crate) => void;
  onDeleted: () => void;
}) {
  const [name, setName] = useState(initial?.name ?? "");
  const [kind, setKind] = useState<"manual" | "smart">(initial?.kind ?? (initialRules ? "smart" : "manual"));
  const [color, setColor] = useState<string | null>(initial?.color ?? null);
  const [category, setCategory] = useState(initial?.category ?? "");
  const [rules, setRules] = useState<RuleSet>(initial?.rules ?? initialRules ?? emptyRuleSet());
  const [preview, setPreview] = useState<{ total: number; sample: TrackRow[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const clean = cleanRuleSet(rules, fields);
  const debounced = useDebounced(JSON.stringify(clean), 250);

  useEffect(() => {
    if (kind !== "smart") return;
    const r = JSON.parse(debounced) as RuleSet | null;
    if (!r || !r.rules.length) {
      setPreview(null);
      return;
    }
    api
      .previewRules(r)
      .then((p) => {
        setPreview(p);
        setError(null);
      })
      .catch((e) => setError(String(e.message ?? e)));
  }, [debounced, kind]);

  const save = async () => {
    setError(null);
    const input = { name, kind, color, category: category || null, rules: kind === "smart" ? clean : null };
    try {
      const c = initial ? await api.updateCrate(initial.id, input) : await api.createCrate(input);
      onSaved(c);
    } catch (e) {
      setError(String((e as Error).message ?? e));
    }
  };

  const canSave = name.trim() && (kind === "manual" || (clean && clean.rules.length > 0));

  return (
    <Dialog
      title={initial ? `Edit crate` : "New crate"}
      onClose={onClose}
      footer={
        <>
          {initial &&
            (confirmDelete ? (
              <>
                <span className="small muted">Delete the crate only? Tracks and files stay.</span>
                <button className="btn danger" onClick={() => api.deleteCrate(initial.id).then(onDeleted)}>
                  Yes, delete crate
                </button>
              </>
            ) : (
              <button className="btn danger" onClick={() => setConfirmDelete(true)}>
                Delete crate
              </button>
            ))}
          <span className="spacer" />
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn primary" disabled={!canSave} onClick={save}>
            {initial ? "Save changes" : "Create crate"}
          </button>
        </>
      }
    >
      <div className="row wrap" style={{ alignItems: "flex-end", gap: 12 }}>
        <label className="field" style={{ flex: 2, minWidth: 220 }}>
          Name
          <input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Afrobeats 2010s peak time" maxLength={120} />
        </label>
        <label className="field" style={{ flex: 1, minWidth: 150 }}>
          Category (optional)
          <input className="input" value={category} onChange={(e) => setCategory(e.target.value)} placeholder="e.g. Weddings, Utility" />
        </label>
      </div>
      <div className="row wrap" style={{ gap: 24 }}>
        <fieldset className="row" style={{ border: 0, padding: 0, margin: 0 }} disabled={!!initial}>
          <legend className="small muted" style={{ marginBottom: 4 }}>
            Type
          </legend>
          <label className="row small">
            <input type="radio" name="kind" checked={kind === "manual"} onChange={() => setKind("manual")} /> Manual — you add tracks
          </label>
          <label className="row small">
            <input type="radio" name="kind" checked={kind === "smart"} onChange={() => setKind("smart")} /> Smart — rules pick tracks
          </label>
        </fieldset>
        <div>
          <div className="small muted" style={{ marginBottom: 4 }}>
            Colour
          </div>
          <ColorPicker value={color} onChange={setColor} />
        </div>
      </div>
      {kind === "smart" && (
        <>
          <RuleBuilder value={rules} onChange={setRules} fields={fields} />
          <div className="preview" aria-live="polite">
            <div className="preview-head">
              <strong>Preview</strong>
              <span className="muted">{preview ? `${plural(preview.total, "track")} match right now` : "Add a complete rule to see matching tracks"}</span>
            </div>
            {preview && preview.sample.length > 0 && (
              <ul>
                {preview.sample.slice(0, 50).map((t) => (
                  <li key={t.id}>
                    <span style={{ flex: 1 }}>
                      {text(t.artist)} — {t.title ?? t.file_name}
                    </span>
                    <span className="faint">{text(t.genre)}</span>
                    <span className="faint">{text(t.year)}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <p className="note">Smart crates update automatically as your library changes. You can still add tracks by hand, and removing a track from a smart crate excludes it.</p>
        </>
      )}
      {error && (
        <div className="notice" role="alert">
          {error}
        </div>
      )}
    </Dialog>
  );
}

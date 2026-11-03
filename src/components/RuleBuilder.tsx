import type { FieldInfo, RuleNode, RuleSet } from "../types";
import { ENUM_VALUES, OPS, describe } from "../lib/rules";
import { Icon } from "./Icon";

type Cond = Extract<RuleNode, { kind: "condition" }>;

function defaultOp(f: FieldInfo): string {
  return OPS[f.type][0].id;
}

function ConditionRow({ c, fields, onChange, onRemove, idx, section }: { c: Cond; fields: FieldInfo[]; onChange: (c: Cond) => void; onRemove: () => void; idx: number; section: string }) {
  const f = fields.find((x) => x.id === c.field) ?? fields[0];
  const ops = OPS[f.type];
  const op = ops.find((o) => o.id === c.op) ?? ops[0];
  const label = `${section} rule ${idx + 1}`;
  const value = c.value;
  return (
    <div className="rule">
      <select
        className="select"
        aria-label={`${label} field`}
        value={f.id}
        onChange={(e) => {
          const nf = fields.find((x) => x.id === e.target.value)!;
          onChange({ kind: "condition", field: nf.id, op: defaultOp(nf), value: nf.type === "number" ? ["", ""] : "" });
        }}
      >
        {fields.map((x) => (
          <option key={x.id} value={x.id}>
            {x.label}
          </option>
        ))}
      </select>
      <select
        className="select"
        aria-label={`${label} operator`}
        value={op.id}
        onChange={(e) => {
          const no = ops.find((o) => o.id === e.target.value)!;
          const v = no.arity === 2 ? (Array.isArray(value) ? value : [value ?? "", ""]) : no.arity === 1 ? (Array.isArray(value) ? value[0] : value) : null;
          onChange({ ...c, op: no.id, value: v });
        }}
      >
        {ops.map((o) => (
          <option key={o.id} value={o.id}>
            {o.label}
          </option>
        ))}
      </select>
      {op.arity === 0 ? (
        <span />
      ) : op.arity === 2 ? (
        <span className="range">
          <input className="input" inputMode="decimal" aria-label={`${label} minimum`} placeholder="min" value={String((value as unknown[])?.[0] ?? "")} onChange={(e) => onChange({ ...c, value: [e.target.value, (value as unknown[])?.[1] ?? ""] })} />
          <span className="faint">to</span>
          <input className="input" inputMode="decimal" aria-label={`${label} maximum`} placeholder="max" value={String((value as unknown[])?.[1] ?? "")} onChange={(e) => onChange({ ...c, value: [(value as unknown[])?.[0] ?? "", e.target.value] })} />
        </span>
      ) : ENUM_VALUES[f.id] ? (
        <select className="select" aria-label={`${label} value`} value={String(value ?? "")} onChange={(e) => onChange({ ...c, value: e.target.value })}>
          <option value="">Choose…</option>
          {ENUM_VALUES[f.id].map((v) => (
            <option key={v.value} value={v.value}>
              {v.label}
            </option>
          ))}
        </select>
      ) : (
        <input className="input" aria-label={`${label} value`} inputMode={f.type === "number" ? "decimal" : undefined} value={String(value ?? "")} onChange={(e) => onChange({ ...c, value: e.target.value })} />
      )}
      <button type="button" className="btn ghost icon" onClick={onRemove} aria-label={`Remove ${label}`}>
        <Icon name="close" />
      </button>
    </div>
  );
}

function Section({ title, nodes, fields, onChange, section }: { title: React.ReactNode; nodes: RuleNode[]; fields: FieldInfo[]; onChange: (n: RuleNode[]) => void; section: string }) {
  return (
    <div className="rules">
      <div className="rules-head">{title}</div>
      {nodes.map((n, i) =>
        n.kind === "condition" ? (
          <ConditionRow
            key={i}
            idx={i}
            section={section}
            c={n}
            fields={fields}
            onChange={(c) => onChange(nodes.map((x, j) => (j === i ? c : x)))}
            onRemove={() => onChange(nodes.filter((_, j) => j !== i))}
          />
        ) : (
          <div className="rule" key={i}>
            <span className="small" style={{ gridColumn: "1 / 4" }}>
              {describe(n, fields)}
            </span>
            <button type="button" className="btn ghost icon" aria-label="Remove group" onClick={() => onChange(nodes.filter((_, j) => j !== i))}>
              <Icon name="close" />
            </button>
          </div>
        ),
      )}
      <div>
        <button type="button" className="btn small" onClick={() => onChange([...nodes, { kind: "condition", field: fields[0].id, op: defaultOp(fields[0]), value: "" }])}>
          <Icon name="plus" size={14} /> Add {section === "Exclude" ? "exclusion" : "rule"}
        </button>
      </div>
    </div>
  );
}

export function RuleBuilder({ value, onChange, fields }: { value: RuleSet; onChange: (r: RuleSet) => void; fields: FieldInfo[] }) {
  if (!fields.length) return <p className="muted">Loading fields…</p>;
  return (
    <div className="rules" style={{ gap: 16 }}>
      <Section
        section="Include"
        title={
          <>
            Match
            <select className="select" aria-label="Match all or any" value={value.match} onChange={(e) => onChange({ ...value, match: e.target.value as RuleSet["match"] })} style={{ height: 28 }}>
              <option value="all">all of</option>
              <option value="any">any of</option>
            </select>
            these rules
          </>
        }
        nodes={value.rules}
        fields={fields}
        onChange={(rules) => onChange({ ...value, rules })}
      />
      <Section section="Exclude" title="Exclude tracks matching any of" nodes={value.exclude ?? []} fields={fields} onChange={(exclude) => onChange({ ...value, exclude })} />
      <p className="note">Unknown values never match a rule. For example, a track without an energy rating is not included by “Energy between 6 and 8”.</p>
    </div>
  );
}

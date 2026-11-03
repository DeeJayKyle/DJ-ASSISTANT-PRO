import type { FieldInfo, RuleNode, RuleSet } from "../types";

export const OPS: Record<FieldInfo["type"], { id: string; label: string; arity: 0 | 1 | 2 }[]> = {
  text: [
    { id: "contains", label: "contains", arity: 1 },
    { id: "equals", label: "is", arity: 1 },
    { id: "not_contains", label: "does not contain", arity: 1 },
    { id: "not_equals", label: "is not", arity: 1 },
    { id: "starts_with", label: "starts with", arity: 1 },
    { id: "is_empty", label: "is unknown", arity: 0 },
    { id: "is_not_empty", label: "is known", arity: 0 },
  ],
  number: [
    { id: "between", label: "between", arity: 2 },
    { id: "eq", label: "=", arity: 1 },
    { id: "gte", label: "≥", arity: 1 },
    { id: "lte", label: "≤", arity: 1 },
    { id: "gt", label: ">", arity: 1 },
    { id: "lt", label: "<", arity: 1 },
    { id: "neq", label: "≠", arity: 1 },
    { id: "is_empty", label: "is unknown", arity: 0 },
    { id: "is_not_empty", label: "is known", arity: 0 },
  ],
  enum: [
    { id: "equals", label: "is", arity: 1 },
    { id: "not_equals", label: "is not", arity: 1 },
    { id: "is_empty", label: "is unknown", arity: 0 },
    { id: "is_not_empty", label: "is known", arity: 0 },
  ],
  tag: [
    { id: "has", label: "has tag", arity: 1 },
    { id: "not_has", label: "does not have tag", arity: 1 },
    { id: "is_empty", label: "has no tags", arity: 0 },
  ],
  bool: [
    { id: "is_true", label: "yes", arity: 0 },
    { id: "is_false", label: "no", arity: 0 },
  ],
};

export const ENUM_VALUES: Record<string, { value: string; label: string }[]> = {
  quality: [
    { value: "lossless", label: "Lossless" },
    { value: "lossy", label: "Lossy" },
    { value: "low_bitrate", label: "Low bitrate" },
    { value: "unknown", label: "Unknown" },
  ],
  status: [
    { value: "ok", label: "OK" },
    { value: "error", label: "Unreadable" },
    { value: "unsupported", label: "Unsupported" },
    { value: "offline", label: "Offline" },
    { value: "missing", label: "Missing" },
  ],
  clean_explicit: [
    { value: "clean", label: "Clean" },
    { value: "explicit", label: "Explicit" },
  ],
  color: ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "grey"].map((c) => ({ value: c, label: c[0].toUpperCase() + c.slice(1) })),
  extension: ["mp3", "flac", "wav", "aiff", "aif", "m4a", "ogg", "opus", "wma"].map((e) => ({ value: e, label: e.toUpperCase() })),
};

export interface Condition {
  field: string;
  op: string;
  value?: unknown;
}

export function cond(field: string, op: string, value?: unknown): RuleNode {
  return { kind: "condition", field, op, value: value ?? null };
}

export function emptyRuleSet(): RuleSet {
  return { match: "all", rules: [], exclude: [] };
}

/** True if a condition has all the values its operator needs. */
export function isComplete(c: Condition, fields: FieldInfo[]): boolean {
  const f = fields.find((x) => x.id === c.field);
  if (!f) return false;
  const op = OPS[f.type].find((o) => o.id === c.op);
  if (!op) return false;
  if (op.arity === 0) return true;
  if (op.arity === 2) {
    return Array.isArray(c.value) && c.value.length === 2 && c.value.every((v) => v !== "" && v != null && !Number.isNaN(Number(v)));
  }
  if (f.type === "number") return c.value !== "" && c.value != null && !Number.isNaN(Number(c.value));
  return typeof c.value === "string" && c.value.trim() !== "";
}

/** Normalise UI values (numbers typed as strings) before sending. */
export function normalise(c: Condition, fields: FieldInfo[]): RuleNode {
  const f = fields.find((x) => x.id === c.field);
  let value = c.value;
  if (f?.type === "number") {
    value = Array.isArray(value) ? value.map(Number) : value == null || value === "" ? null : Number(value);
  }
  return cond(c.field, c.op, value);
}

export function describe(node: RuleNode, fields: FieldInfo[]): string {
  if (node.kind === "group") {
    return "(" + node.rules.map((r) => describe(r, fields)).join(node.match === "all" ? " and " : " or ") + ")";
  }
  const f = fields.find((x) => x.id === node.field);
  const label = f?.label ?? node.field;
  const op = f ? OPS[f.type].find((o) => o.id === node.op) : undefined;
  const opLabel = op?.label ?? node.op;
  const enumLabel = (v: unknown) => ENUM_VALUES[node.field]?.find((e) => e.value === v)?.label ?? String(v);
  if (!op || op.arity === 0) return `${label} ${opLabel}`;
  if (op.arity === 2 && Array.isArray(node.value)) return `${label} ${node.value[0]}–${node.value[1]}`;
  return `${label} ${opLabel} ${enumLabel(node.value)}`;
}

export function countRules(rs: RuleSet | null | undefined): number {
  if (!rs) return 0;
  return rs.rules.length + (rs.exclude?.length ?? 0);
}

/** Drop incomplete conditions and normalise values; returns null if nothing is left. */
export function cleanRuleSet(rs: RuleSet | null | undefined, fields: FieldInfo[]): RuleSet | null {
  if (!rs) return null;
  const clean = (nodes: RuleNode[] = []): RuleNode[] =>
    nodes.flatMap((n) => {
      if (n.kind === "group") {
        const inner = clean(n.rules);
        return inner.length ? [{ ...n, rules: inner }] : [];
      }
      return isComplete(n, fields) ? [normalise(n, fields)] : [];
    });
  const out: RuleSet = { match: rs.match, rules: clean(rs.rules), exclude: clean(rs.exclude) };
  return out.rules.length || out.exclude!.length ? out : null;
}

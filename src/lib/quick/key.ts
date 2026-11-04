/** Camelot neighbours that mix well: same code, ±1 on the wheel, and the relative major/minor. */
export function compatibleCamelot(code: string) {
  const m = code.match(/^(\d+)([AB])$/);
  if (!m) return [];
  const n = Number(m[1]);
  const l = m[2];
  const wrap = (x: number) => ((x - 1 + 12) % 12) + 1;
  return [code, `${wrap(n + 1)}${l}`, `${wrap(n - 1)}${l}`, `${n}${l === "A" ? "B" : "A"}`];
}

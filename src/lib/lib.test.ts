import { describe as d, expect, it } from "vitest";
import { bytes, duration, bpm, text, UNKNOWN } from "./format";
import { describe as describeRule, isComplete, normalise, cond } from "./rules";
import type { FieldInfo } from "../types";

const fields: FieldInfo[] = [
  { id: "genre", label: "Genre", type: "text" },
  { id: "energy", label: "Energy (1–10)", type: "number" },
  { id: "quality", label: "Quality", type: "enum" },
  { id: "tag", label: "Tag", type: "tag" },
];

d("format", () => {
  it("shows unknown values as unknown, never invented", () => {
    expect(duration(null)).toBe(UNKNOWN);
    expect(duration(0)).toBe(UNKNOWN);
    expect(bpm(null)).toBe(UNKNOWN);
    expect(text("")).toBe(UNKNOWN);
    expect(bytes(undefined)).toBe(UNKNOWN);
  });
  it("formats durations, sizes and bpm", () => {
    expect(duration(61_000)).toBe("1:01");
    expect(duration(3_726_000)).toBe("1:02:06");
    expect(bytes(1536)).toBe("1.5 KB");
    expect(bytes(10 * 1024 * 1024)).toBe("10 MB");
    expect(bpm(124)).toBe("124");
    expect(bpm(123.456)).toBe("123.5");
  });
});

d("rules", () => {
  it("checks completeness by operator arity", () => {
    expect(isComplete({ field: "genre", op: "contains", value: "" }, fields)).toBe(false);
    expect(isComplete({ field: "genre", op: "is_empty" }, fields)).toBe(true);
    expect(isComplete({ field: "energy", op: "between", value: ["6", "8"] }, fields)).toBe(true);
    expect(isComplete({ field: "energy", op: "between", value: ["6", "x"] }, fields)).toBe(false);
    expect(isComplete({ field: "nope", op: "equals", value: "x" }, fields)).toBe(false);
  });
  it("normalises numbers typed as text", () => {
    expect(normalise({ field: "energy", op: "between", value: ["6", "8"] }, fields)).toEqual(cond("energy", "between", [6, 8]));
  });
  it("describes rules in plain language", () => {
    expect(describeRule(cond("energy", "between", [6, 8]), fields)).toBe("Energy (1–10) 6–8");
    expect(describeRule(cond("quality", "equals", "low_bitrate"), fields)).toBe("Quality is Low bitrate");
    expect(describeRule(cond("genre", "is_empty"), fields)).toBe("Genre is unknown");
  });
});

import { describe, expect, it } from "vitest";
import {
  approxEq,
  idsFromPoints,
  idsToIndices,
  rangeSpec,
  readVisibility,
  scalarSpec,
  selectionSpec,
  slimPoints,
  stringVisibility,
  typedVisibility,
  visibilitySpec,
  type PlotlySpec,
  type PlotlyTrace,
} from "../widgets/plotly/pure";

describe("approxEq", () => {
  it("is true for identical values (incl. non-numbers via ===)", () => {
    expect(approxEq(1, 1)).toBe(true);
    expect(approxEq("a", "a")).toBe(true);
    expect(approxEq(null, null)).toBe(true);
  });
  it("tolerates tiny float drift but rejects real differences", () => {
    expect(approxEq(1, 1 + 1e-9)).toBe(true);
    expect(approxEq(100, 100.5)).toBe(false);
  });
  it("is false when either side is not a number (and not ===)", () => {
    expect(approxEq(1, "1")).toBe(false);
    expect(approxEq(undefined, 1)).toBe(false);
  });
});

describe("idsToIndices", () => {
  const data: PlotlyTrace[] = [
    { ids: ["a", "b", "c"] },
    { ids: ["d", "a"] },
    {}, // trace with no ids
  ];
  it("maps a single id and an array of ids to {trace -> point indices}", () => {
    expect(idsToIndices(data, "a")).toEqual({ 0: [0], 1: [1] });
    expect(idsToIndices(data, ["b", "d"])).toEqual({ 0: [1], 1: [0] });
  });
  it("returns an empty map when nothing matches", () => {
    expect(idsToIndices(data, "zzz")).toEqual({});
  });
  it("ignores traces without ids (indices are in point order)", () => {
    expect(idsToIndices(data, ["a", "b", "c", "d"])).toEqual({
      0: [0, 1, 2],
      1: [0, 1], // trace 1 ids are ["d","a"] -> points 0 and 1
    });
  });
});

describe("idsFromPoints", () => {
  const el = { data: [{ ids: ["a", "b"] }, { ids: ["c"] }] as PlotlyTrace[] };
  it("returns null for null/empty points", () => {
    expect(idsFromPoints(el, null)).toBeNull();
    expect(idsFromPoints(el, [])).toBeNull();
  });
  it("resolves point indices to their ids off the graph data", () => {
    expect(
      idsFromPoints(el, [
        { curveNumber: 0, pointNumber: 1 },
        { curveNumber: 1, pointNumber: 0 },
      ]),
    ).toEqual(["b", "c"]);
  });
  it("skips points whose id is missing, returning null if all miss", () => {
    expect(
      idsFromPoints(el, [{ curveNumber: 0, pointNumber: 9 }]),
    ).toBeNull();
  });
});

describe("visibility helpers", () => {
  it("typedVisibility normalizes strings/booleans to plotly tri-state", () => {
    expect(typedVisibility("true")).toBe(true);
    expect(typedVisibility(true)).toBe(true);
    expect(typedVisibility("false")).toBe(false);
    expect(typedVisibility(false)).toBe(false);
    expect(typedVisibility("legendonly")).toBe("legendonly");
  });
  it("stringVisibility is the inverse (undefined -> 'true')", () => {
    expect(stringVisibility(true)).toBe("true");
    expect(stringVisibility(undefined)).toBe("true");
    expect(stringVisibility(false)).toBe("false");
    expect(stringVisibility("legendonly")).toBe("legendonly");
  });
  it("readVisibility keys by trace name, skipping unnamed traces", () => {
    const el = {
      data: [
        { name: "x", visible: false },
        { name: "y" }, // undefined -> "true"
        { visible: "legendonly" }, // unnamed -> skipped
      ] as PlotlyTrace[],
    };
    expect(readVisibility(el)).toEqual({ x: "false", y: "true" });
  });
});

describe("slimPoints", () => {
  it("returns empty points for null/no-points input", () => {
    expect(slimPoints(null)).toEqual({ points: [] });
    expect(slimPoints({})).toEqual({ points: [] });
  });
  it("projects only the handler-facing fields", () => {
    const out = slimPoints({
      points: [
        { curveNumber: 0, pointNumber: 2, x: 1, y: 2, text: "t", customdata: 9 },
      ],
    });
    expect(out).toEqual({
      points: [
        {
          curveNumber: 0,
          pointNumber: 2,
          x: 1,
          y: 2,
          z: undefined,
          text: "t",
          customdata: 9,
        },
      ],
    });
  });
});

describe("rangeSpec", () => {
  const r = rangeSpec("xaxis");
  it("writeSpec sets the range and disables autorange", () => {
    const s: PlotlySpec = { data: [] };
    r.writeSpec(s, [0, 10]);
    expect(s.layout!.xaxis).toEqual({ range: [0, 10], autorange: false });
  });
  it("matchesCurrent compares approximately", () => {
    const el = { data: [], layout: { xaxis: { range: [0, 10] } } };
    expect(r.matchesCurrent(el, [0, 10 + 1e-9])).toBe(true);
    expect(r.matchesCurrent(el, [0, 11])).toBe(false);
    expect(r.matchesCurrent({ data: [], layout: {} }, [0, 10])).toBe(false);
  });
  it("fromRelayout handles whole-array, split, reset, and abstain", () => {
    expect(r.fromRelayout({ "xaxis.range": [1, 2] })).toEqual([1, 2]);
    expect(r.fromRelayout({ "xaxis.range[0]": 1, "xaxis.range[1]": 2 })).toEqual(
      [1, 2],
    );
    expect(r.fromRelayout({ "xaxis.autorange": true })).toBeNull();
    expect(r.fromRelayout({ "yaxis.range": [1, 2] })).toBeUndefined();
  });
});

describe("scalarSpec", () => {
  const sc = scalarSpec("dragmode");
  it("writeSpec / matchesCurrent / fromRelayout operate on layout[name]", () => {
    const s: PlotlySpec = { data: [] };
    sc.writeSpec(s, "zoom");
    expect(s.layout!.dragmode).toBe("zoom");
    expect(sc.matchesCurrent({ data: [], layout: { dragmode: "zoom" } }, "zoom")).toBe(
      true,
    );
    expect(sc.fromRelayout({ dragmode: "pan" })).toBe("pan");
    expect(sc.fromRelayout({ hovermode: "x" })).toBeUndefined();
  });
});

describe("selectionSpec", () => {
  const sel = selectionSpec();
  const data: PlotlyTrace[] = [{ ids: ["a", "b"] }, { ids: ["c", "d"] }];
  it("writeSpec stamps selectedpoints per trace", () => {
    const s: PlotlySpec = { data: structuredClone(data) };
    sel.writeSpec(s, ["a", "d"]);
    expect(s.data[0].selectedpoints).toEqual([0]);
    expect(s.data[1].selectedpoints).toEqual([1]);
  });
  it("matchesCurrent is identity- and order-insensitive", () => {
    const el = {
      data: [
        { ids: ["a", "b"], selectedpoints: [1, 0] },
        { ids: ["c", "d"], selectedpoints: [] },
      ] as PlotlyTrace[],
    };
    expect(sel.matchesCurrent(el, ["a", "b"])).toBe(true);
    expect(sel.matchesCurrent(el, ["a"])).toBe(false); // length mismatch
  });
});

describe("visibilitySpec", () => {
  const vis = visibilitySpec();
  it("writeSpec applies only named, present keys (sparse)", () => {
    const s: PlotlySpec = {
      data: [{ name: "x" }, { name: "y" }, {}] as PlotlyTrace[],
    };
    vis.writeSpec(s, { x: "legendonly" });
    expect(s.data[0].visible).toBe("legendonly");
    expect(s.data[1].visible).toBeUndefined();
  });
  it("matchesCurrent ignores traces not in the map", () => {
    const el = {
      data: [{ name: "x", visible: false }, { name: "y" }] as PlotlyTrace[],
    };
    expect(vis.matchesCurrent(el, { x: "false" })).toBe(true);
    expect(vis.matchesCurrent(el, { x: "true" })).toBe(false);
  });
});

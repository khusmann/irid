// Pure plotly identity/diff helpers + the pure half of each translation-table
// entry (writeSpec / matchesCurrent / fromRelayout). No Plotly.* calls and no
// DOM mutation — these operate on plain {data, layout} objects and the graph's
// already-rendered el.data/el.layout, so they're directly unit-testable.
//
// The impure half of each entry (apply / applyDeferred, which call
// Plotly.relayout/restyle) lives in index.ts and composes these.

export interface PlotlyTrace {
  name?: string | null;
  ids?: Array<string | number>;
  visible?: boolean | "legendonly";
  selectedpoints?: number[];
  [k: string]: unknown;
}

export interface PlotlyLayout {
  uirevision?: unknown;
  [k: string]: unknown;
}

export interface PlotlySpec {
  data: PlotlyTrace[];
  layout?: PlotlyLayout;
  config?: Record<string, unknown>;
}

/** The plotly graph div after a render: Plotly attaches data/layout/on. */
export interface PlotlyGraph {
  data: PlotlyTrace[];
  layout?: PlotlyLayout;
}

/** A point as it arrives in a plotly event (curve/point index + projected fields). */
export interface PlotlyPoint {
  curveNumber: number;
  pointNumber: number;
  x?: unknown;
  y?: unknown;
  z?: unknown;
  text?: unknown;
  customdata?: unknown;
}

export type IdValue = string | number;
export type Selection = IdValue | IdValue[];
export type Visibility = boolean | "legendonly";
/** Sparse { traceName -> tri-state } visibility map. */
export type VisibilityMap = Record<string, Visibility | string>;
/** A relayout payload: keys like "xaxis.range", "xaxis.range[0]", "dragmode". */
export type RelayoutPayload = Record<string, unknown>;

export function approxEq(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "number" || typeof b !== "number") return false;
  return Math.abs(a - b) < 1e-6 * (Math.abs(a) + Math.abs(b) + 1);
}

// event points -> their id values, read off the graph (the point object doesn't
// carry the id, but the listener has curve/point and gd.data[*].ids does).
export function idsFromPoints(
  el: PlotlyGraph,
  points: PlotlyPoint[] | null | undefined,
): IdValue[] | null {
  if (!points || !points.length) return null;
  const out: IdValue[] = [];
  points.forEach((p) => {
    const ids = el.data[p.curveNumber] && el.data[p.curveNumber].ids;
    if (ids && ids[p.pointNumber] != null) out.push(ids[p.pointNumber]);
  });
  return out.length ? out : null;
}

// ids -> { traceIndex -> [0-based point indices] } against the given data.
export function idsToIndices(
  data: PlotlyTrace[],
  ids: Selection,
): Record<number, number[]> {
  const want: Record<string, boolean> = {};
  ([] as IdValue[]).concat(ids).forEach((k) => {
    want[String(k)] = true;
  });
  const g: Record<number, number[]> = {};
  data.forEach((tr, i) => {
    (tr.ids || []).forEach((id, j) => {
      if (want[String(id)]) {
        if (!g[i]) g[i] = [];
        g[i].push(j);
      }
    });
  });
  return g;
}

export function typedVisibility(s: Visibility | string): Visibility {
  if (s === "true" || s === true) return true;
  if (s === "false" || s === false) return false;
  return s as Visibility; // "legendonly"
}

export function stringVisibility(v: Visibility | undefined): string {
  if (v === false) return "false";
  if (v === "legendonly") return "legendonly";
  return "true"; // true or undefined
}

// Visibility keyed by trace NAME (identity), not position — a sparse map. Traces
// without a name can't be keyed and are skipped.
export function readVisibility(el: PlotlyGraph): Record<string, string> {
  const out: Record<string, string> = {};
  el.data.forEach((tr) => {
    if (tr.name != null) out[tr.name] = stringVisibility(tr.visible);
  });
  return out;
}

// plotly point objects reference data/fullData (circular, huge) — never let those
// reach JSON.stringify. Project to the fields a handler actually wants.
export function slimPoints(e: { points?: PlotlyPoint[] } | null | undefined): {
  points: Array<Record<string, unknown>>;
} {
  if (!e || !e.points) return { points: [] };
  return {
    points: e.points.map((p) => ({
      curveNumber: p.curveNumber,
      pointNumber: p.pointNumber,
      x: p.x,
      y: p.y,
      z: p.z,
      text: p.text,
      customdata: p.customdata,
    })),
  };
}

// --- pure entry halves ----------------------------------------------------

export interface RangeScalarPure {
  writeSpec(s: PlotlySpec, v: unknown): void;
  matchesCurrent(el: PlotlyGraph, v: unknown): boolean;
  fromRelayout(p: RelayoutPayload): unknown;
}

export interface SelectionVisibilityPure {
  writeSpec(s: PlotlySpec, v: unknown): void;
  matchesCurrent(el: PlotlyGraph, v: unknown): boolean;
}

export function rangeSpec(axis: string): RangeScalarPure {
  const rk = axis + ".range";
  return {
    writeSpec(s, v) {
      if (!s.layout) s.layout = {};
      if (!s.layout[axis]) s.layout[axis] = {};
      const ax = s.layout[axis] as Record<string, unknown>;
      ax.range = v;
      ax.autorange = false;
    },
    matchesCurrent(el, v) {
      const ax = el.layout && (el.layout[axis] as Record<string, unknown>);
      const cur = ax && (ax.range as unknown[]);
      const vv = v as unknown[];
      return !!cur && approxEq(cur[0], vv[0]) && approxEq(cur[1], vv[1]);
    },
    fromRelayout(p) {
      if (p[rk] !== undefined) return p[rk]; // whole-array
      const lo = p[axis + ".range[0]"];
      const hi = p[axis + ".range[1]"];
      if (lo !== undefined && hi !== undefined) return [lo, hi]; // split
      if (p[axis + ".autorange"] === true) return null; // reset
      return undefined; // abstain
    },
  };
}

export function scalarSpec(name: string): RangeScalarPure {
  return {
    writeSpec(s, v) {
      if (!s.layout) s.layout = {};
      s.layout[name] = v;
    },
    matchesCurrent(el, v) {
      return !!el.layout && el.layout[name] === v;
    },
    fromRelayout(p) {
      return p[name]; // undefined if absent
    },
  };
}

export function selectionSpec(): SelectionVisibilityPure {
  return {
    writeSpec(s, v) {
      const g = idsToIndices(s.data, v as Selection);
      s.data.forEach((tr, i) => {
        if (g[i]) tr.selectedpoints = g[i];
      });
    },
    // True when the graph ALREADY shows exactly this selection (the echo of a
    // user's own drag). Skipping it leaves their marquee intact.
    matchesCurrent(el, v) {
      const g = idsToIndices(el.data, v as Selection);
      return el.data.every((tr, i) => {
        const want = g[i] || [];
        const have = tr.selectedpoints || [];
        if (want.length !== have.length) return false;
        const hs: Record<number, boolean> = {};
        have.forEach((x) => {
          hs[x] = true;
        });
        return want.every((x) => hs[x]);
      });
    },
  };
}

export function visibilitySpec(): SelectionVisibilityPure {
  return {
    writeSpec(s, v) {
      const vm = v as VisibilityMap;
      s.data.forEach((tr) => {
        if (tr.name != null && vm[tr.name] !== undefined) {
          tr.visible = typedVisibility(vm[tr.name]);
        }
      });
    },
    matchesCurrent(el, v) {
      const vm = v as VisibilityMap;
      return el.data.every((tr) => {
        if (tr.name == null || vm[tr.name] === undefined) return true;
        return stringVisibility(tr.visible) === String(vm[tr.name]);
      });
    },
  };
}

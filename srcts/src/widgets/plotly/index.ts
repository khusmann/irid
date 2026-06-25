// irid-plotly widget factory. Registers irid.defineWidget("plotly", ...) and owns
// the Plotly.react/relayout/restyle/purge glue plus its mirror of the R-side
// translation table. The pure half of each table entry (writeSpec/matchesCurrent/
// fromRelayout) and the identity/diff helpers live in ./pure; this file composes
// them with the impure apply/applyDeferred (Plotly.* calls) behind the mutate guard.
//
// Load order: delivered via insertUI at mount time, always after irid.js, so
// window.irid.defineWidget exists. The plotly-main global may not have executed
// yet, so the factory is async and awaits waitForPlotly() before touching Plotly.

import {
  idsFromPoints,
  idsToIndices,
  rangeSpec,
  readVisibility,
  scalarSpec,
  selectionSpec,
  slimPoints,
  typedVisibility,
  visibilitySpec,
  type IdValue,
  type PlotlyGraph,
  type PlotlySpec,
  type RelayoutPayload,
  type VisibilityMap,
} from "./pure";
import type { SetProp, WidgetHandle, WidgetProps } from "../../protocol";

interface PlotlyHTMLElement extends HTMLElement {
  data: PlotlyTrace[];
  layout: PlotlyLayout;
  on(event: string, handler: (payload: any) => void | boolean): void;
}
// Re-import the trace/layout types via PlotlyGraph's shape for el typing.
type PlotlyTrace = PlotlySpec["data"][number];
type PlotlyLayout = NonNullable<PlotlySpec["layout"]>;

interface PlotlyStatic {
  react(
    el: HTMLElement,
    data: unknown,
    layout: unknown,
    config?: unknown,
  ): Promise<PlotlyHTMLElement>;
  relayout(el: HTMLElement, update: Record<string, unknown>): Promise<unknown>;
  restyle(
    el: HTMLElement,
    update: Record<string, unknown>,
    traces?: number[],
  ): Promise<unknown>;
  purge(el: HTMLElement): void;
}

declare global {
  interface Window {
    Plotly?: PlotlyStatic;
  }
}

interface Entry {
  name: string;
  source: "relayout" | "selected" | "restyle";
  writeSpec(s: PlotlySpec, v: unknown): void;
  matchesCurrent(el: PlotlyGraph, v: unknown): boolean;
  fromRelayout?(p: RelayoutPayload): unknown;
  apply(el: PlotlyHTMLElement, v: unknown): Promise<unknown>;
  applyDeferred(el: PlotlyHTMLElement, spec: PlotlySpec): Promise<unknown>;
}

function deepCopy<T>(o: T): T {
  return JSON.parse(JSON.stringify(o)) as T;
}

function waitForPlotly(): Promise<PlotlyStatic> {
  if (window.Plotly) return Promise.resolve(window.Plotly);
  return new Promise((resolve) => {
    const t = setInterval(() => {
      if (window.Plotly) {
        clearInterval(t);
        resolve(window.Plotly);
      }
    }, 30);
  });
}

window.irid.defineWidget(
  "plotly",
  async function (
    el: HTMLElement,
    props: WidgetProps,
    sendEvent,
    setProp: SetProp,
  ): Promise<WidgetHandle> {
    const Plotly = await waitForPlotly(); // captured local; defined from here on
    const gd = el as PlotlyHTMLElement;

    let applyDepth = 0; // >0 while our own graph mutations run
    let listenersAttached = false;
    let ready = false; // first render committed?
    let spec: PlotlySpec = JSON.parse(props.spec as string);
    const state: Record<string, unknown> = {};

    function applying(): boolean {
      return applyDepth > 0;
    }

    // Every programmatic mutation runs through this guard. react() is silent;
    // relayout()/restyle() echo a synchronous plotly_relayout the listener must
    // ignore. A depth COUNTER (not a boolean) so concurrent batch mutations don't
    // clear the guard early and leak a deferred echo.
    function mutate<T>(fn: () => T | Promise<T>): Promise<T> {
      applyDepth++;
      let p: T | Promise<T>;
      try {
        p = fn();
      } catch (err) {
        applyDepth--;
        throw err;
      }
      return Promise.resolve(p).then(
        (r) => {
          applyDepth--;
          return r;
        },
        (err) => {
          applyDepth--;
          throw err;
        },
      );
    }

    // ---- translation-table entries (pure half from ./pure + Plotly glue) ----

    function rangeEntry(name: string, axis: string): Entry {
      const pure = rangeSpec(axis);
      const rk = axis + ".range";
      return {
        name,
        source: "relayout",
        writeSpec: pure.writeSpec,
        matchesCurrent: pure.matchesCurrent,
        fromRelayout: pure.fromRelayout,
        apply(el2, v) {
          const u: Record<string, unknown> = {};
          u[rk] = v;
          u[axis + ".autorange"] = false;
          return mutate(() => Plotly.relayout(el2, u));
        },
        applyDeferred(el2, spec2) {
          const ax =
            spec2.layout && (spec2.layout[axis] as Record<string, unknown>);
          const sr = ax && ax.range;
          const u: Record<string, unknown> = {};
          if (sr != null) {
            u[rk] = sr;
            u[axis + ".autorange"] = false;
          } else {
            u[axis + ".autorange"] = true;
          }
          return mutate(() => Plotly.relayout(el2, u));
        },
      };
    }

    function scalarEntry(name: string): Entry {
      const pure = scalarSpec(name);
      return {
        name,
        source: "relayout",
        writeSpec: pure.writeSpec,
        matchesCurrent: pure.matchesCurrent,
        fromRelayout: pure.fromRelayout,
        apply(el2, v) {
          const u: Record<string, unknown> = {};
          u[name] = v;
          return mutate(() => Plotly.relayout(el2, u));
        },
        applyDeferred(el2, spec2) {
          const sv = spec2.layout ? spec2.layout[name] : undefined;
          const u: Record<string, unknown> = {};
          u[name] = sv == null ? null : sv;
          return mutate(() => Plotly.relayout(el2, u));
        },
      };
    }

    function selectionEntry(): Entry {
      const pure = selectionSpec();
      return {
        name: "selected_ids",
        source: "selected",
        writeSpec: pure.writeSpec,
        matchesCurrent: pure.matchesCurrent,
        // Both set and clear must drop the active drag selection FIRST: while one
        // is active plotly owns selectedpoints, so a bare restyle is a no-op. So
        // clear layout.selections, THEN restyle the per-point dimming.
        apply(el2, v) {
          const ids: IdValue[] =
            v == null ? [] : ([] as IdValue[]).concat(v as IdValue | IdValue[]);
          const g = idsToIndices(el2.data, ids);
          // An EMPTY selection is a clear (every trace -> null, full opacity); a
          // non-empty selection dims the rest (unmatched trace -> []).
          const empty = ids.length === 0;
          const sel = el2.data.map((_, i) => (empty ? null : g[i] || []));
          return mutate(() =>
            Plotly.relayout(el2, { selections: null }).then(() =>
              Plotly.restyle(el2, { selectedpoints: sel }),
            ),
          );
        },
        applyDeferred(el2) {
          const sel = el2.data.map(() => null);
          return mutate(() =>
            Plotly.relayout(el2, { selections: null }).then(() =>
              Plotly.restyle(el2, { selectedpoints: sel }),
            ),
          );
        },
      };
    }

    function visibilityEntry(): Entry {
      const pure = visibilitySpec();
      return {
        name: "trace_visibility",
        source: "restyle",
        writeSpec: pure.writeSpec,
        matchesCurrent: pure.matchesCurrent,
        apply(el2, v) {
          const vm = v as VisibilityMap;
          const idx: number[] = [];
          const vals: unknown[] = [];
          el2.data.forEach((tr, i) => {
            if (tr.name != null && vm[tr.name] !== undefined) {
              idx.push(i);
              vals.push(typedVisibility(vm[tr.name]));
            }
          });
          if (!idx.length) return Promise.resolve();
          return mutate(() => Plotly.restyle(el2, { visible: vals }, idx));
        },
        applyDeferred() {
          return Promise.resolve(); // null -> leave the spec's visibility
        },
      };
    }

    function makeEntry(name: string): Entry | null {
      const m = name.match(/^([xy]axis\d*)_range$/);
      if (m) return rangeEntry(name, m[1]);
      if (name === "dragmode" || name === "hovermode") return scalarEntry(name);
      if (name === "selected_ids") return selectionEntry();
      if (name === "trace_visibility") return visibilityEntry();
      return null; // unknown — R side already rejected these; ignore defensively
    }

    // Build entries from the explicit bound-key list, not Object.keys(props): a
    // NULL-initialized state arg is dropped from the init props object.
    const stateKeys = ([] as string[]).concat(
      (props.__irid_state_keys as string | string[] | undefined) || [],
    );
    const entries: Entry[] = [];
    stateKeys.forEach((key) => {
      const e = makeEntry(key);
      if (e) {
        entries.push(e);
        state[key] = key in props ? props[key] : null;
      }
    });

    // ---- render ------------------------------------------------------------

    function merge(): PlotlySpec {
      const s = deepCopy(spec);
      if (!s.layout) s.layout = {};
      if (s.layout.uirevision == null) s.layout.uirevision = "irid";
      entries.forEach((entry) => {
        const v = state[entry.name];
        if (v != null) entry.writeSpec(s, v);
      });
      return s;
    }

    function render(): Promise<void> {
      return mutate(() => {
        const m = merge();
        return Plotly.react(gd, m.data, m.layout, m.config || {});
      }).then(() => {
        ready = true;
        if (!listenersAttached) {
          attachListeners();
          listenersAttached = true;
        }
        // Readiness marker: rendered AND listeners wired (an external observer
        // dispatching a gesture must wait for this).
        gd.setAttribute("data-irid-plotly-ready", "1");
      });
    }

    function attachListeners(): void {
      gd.on("plotly_relayout", (payload: RelayoutPayload) => {
        if (applying()) return; // our own relayout/restyle echo
        const keys = Object.keys(payload);
        // Plotly fires a bare {} relayout on some interactions; drop it.
        if (!keys.length) return;
        sendEvent("relayout", payload); // raw escape hatch (no-op if unbound)
        entries.forEach((entry) => {
          if (entry.source !== "relayout" || !entry.fromRelayout) return;
          const v = entry.fromRelayout(payload);
          if (v !== undefined) setProp(entry.name, v); // value | null
        });
      });
      gd.on("plotly_selected", (e: { points?: any[] } | undefined) => {
        if (applying()) return;
        setProp("selected_ids", idsFromPoints(gd, e && e.points));
      });
      gd.on("plotly_selecting", (e: any) => {
        if (applying()) return;
        sendEvent("selecting", slimPoints(e));
      });
      gd.on("plotly_deselect", () => {
        if (applying()) return; // a data-change react() deselects — our mutation
        setProp("selected_ids", null);
        sendEvent("deselect", {});
      });
      gd.on("plotly_restyle", () => {
        if (applying()) return;
        setProp("trace_visibility", readVisibility(gd));
      });
      gd.on("plotly_click", (e: any) => {
        sendEvent("click", slimPoints(e));
      });
      gd.on("plotly_hover", (e: any) => {
        sendEvent("hover", slimPoints(e));
      });
      gd.on("plotly_unhover", () => {
        sendEvent("unhover", {});
      });
      gd.on("plotly_doubleclick", () => {
        sendEvent("doubleclick", {});
      });
      gd.on("plotly_legendclick", (e: any) => {
        sendEvent("legend-click", { curveNumber: e.curveNumber });
        return true;
      });
      gd.on("plotly_legenddoubleclick", (e: any) => {
        sendEvent("legend-doubleclick", { curveNumber: e.curveNumber });
        return true;
      });
      gd.on("plotly_clickannotation", (e: any) => {
        sendEvent("click-annotation", { index: e.index, annotation: e.annotation });
      });
      gd.on("plotly_sunburstclick", (e: any) => {
        sendEvent("sunburst-click", slimPoints(e));
      });
    }

    render();

    // ---- server -> client batch -------------------------------------------

    return {
      update(values: Record<string, unknown>) {
        const reactNeeded = "spec" in values;
        if (reactNeeded) spec = JSON.parse(values.spec as string);
        entries.forEach((entry) => {
          if (!(entry.name in values)) return;
          const v = values[entry.name];
          state[entry.name] = v;
          // Before the first render commits (or with a spec change in the same
          // batch), the upcoming render() folds in this state.
          if (reactNeeded || !ready) return;
          if (v == null) entry.applyDeferred(gd, spec); // reset
          else if (!entry.matchesCurrent(gd, v)) entry.apply(gd, v); // snap/apply
        });
        if (reactNeeded || !ready) render(); // one redraw for the whole batch
      },
      destroy() {
        Plotly.purge(gd);
      },
    };
  },
);

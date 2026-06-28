"use strict";
(() => {
  // src/widgets/plotly/pure.ts
  function approxEq(a, b) {
    if (a === b) return true;
    if (typeof a !== "number" || typeof b !== "number") return false;
    return Math.abs(a - b) < 1e-6 * (Math.abs(a) + Math.abs(b) + 1);
  }
  function idsFromPoints(el, points) {
    if (!points || !points.length) return null;
    const out = [];
    points.forEach((p) => {
      const ids = el.data[p.curveNumber] && el.data[p.curveNumber].ids;
      if (ids && ids[p.pointNumber] != null) out.push(ids[p.pointNumber]);
    });
    return out.length ? out : null;
  }
  function idsToIndices(data, ids) {
    const want = {};
    [].concat(ids).forEach((k) => {
      want[String(k)] = true;
    });
    const g = {};
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
  function typedVisibility(s) {
    if (s === "true" || s === true) return true;
    if (s === "false" || s === false) return false;
    return s;
  }
  function stringVisibility(v) {
    if (v === false) return "false";
    if (v === "legendonly") return "legendonly";
    return "true";
  }
  function readVisibility(el) {
    const out = {};
    el.data.forEach((tr) => {
      if (tr.name != null) out[tr.name] = stringVisibility(tr.visible);
    });
    return out;
  }
  function slimPoints(e) {
    if (!e || !e.points) return { points: [] };
    return {
      points: e.points.map((p) => ({
        curveNumber: p.curveNumber,
        pointNumber: p.pointNumber,
        x: p.x,
        y: p.y,
        z: p.z,
        text: p.text,
        customdata: p.customdata
      }))
    };
  }
  function rangeSpec(axis) {
    const rk = axis + ".range";
    return {
      writeSpec(s, v) {
        if (!s.layout) s.layout = {};
        if (!s.layout[axis]) s.layout[axis] = {};
        const ax = s.layout[axis];
        ax.range = v;
        ax.autorange = false;
      },
      matchesCurrent(el, v) {
        const ax = el.layout && el.layout[axis];
        const cur = ax && ax.range;
        const vv = v;
        return !!cur && approxEq(cur[0], vv[0]) && approxEq(cur[1], vv[1]);
      },
      fromRelayout(p) {
        if (p[rk] !== void 0) return p[rk];
        const lo = p[axis + ".range[0]"];
        const hi = p[axis + ".range[1]"];
        if (lo !== void 0 && hi !== void 0) return [lo, hi];
        if (p[axis + ".autorange"] === true) return null;
        return void 0;
      }
    };
  }
  function scalarSpec(name) {
    return {
      writeSpec(s, v) {
        if (!s.layout) s.layout = {};
        s.layout[name] = v;
      },
      matchesCurrent(el, v) {
        return !!el.layout && el.layout[name] === v;
      },
      fromRelayout(p) {
        return p[name];
      }
    };
  }
  function selectionSpec() {
    return {
      writeSpec(s, v) {
        const g = idsToIndices(s.data, v);
        s.data.forEach((tr, i) => {
          if (g[i]) tr.selectedpoints = g[i];
        });
      },
      // True when the graph ALREADY shows exactly this selection (the echo of a
      // user's own drag). Skipping it leaves their marquee intact.
      matchesCurrent(el, v) {
        const g = idsToIndices(el.data, v);
        return el.data.every((tr, i) => {
          const want = g[i] || [];
          const have = tr.selectedpoints || [];
          if (want.length !== have.length) return false;
          const hs = {};
          have.forEach((x) => {
            hs[x] = true;
          });
          return want.every((x) => hs[x]);
        });
      }
    };
  }
  function visibilitySpec() {
    return {
      writeSpec(s, v) {
        const vm = v;
        s.data.forEach((tr) => {
          if (tr.name != null && vm[tr.name] !== void 0) {
            tr.visible = typedVisibility(vm[tr.name]);
          }
        });
      },
      matchesCurrent(el, v) {
        const vm = v;
        return el.data.every((tr) => {
          if (tr.name == null || vm[tr.name] === void 0) return true;
          return stringVisibility(tr.visible) === String(vm[tr.name]);
        });
      }
    };
  }

  // src/widgets/plotly/index.ts
  function deepCopy(o) {
    return JSON.parse(JSON.stringify(o));
  }
  function waitForPlotly() {
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
    async function(el, props, sendEvent, setProp) {
      const Plotly = await waitForPlotly();
      const gd = el;
      let applyDepth = 0;
      let listenersAttached = false;
      let ready = false;
      let spec = JSON.parse(props.spec);
      const state = {};
      function applying() {
        return applyDepth > 0;
      }
      function mutate(fn) {
        applyDepth++;
        let p;
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
          }
        );
      }
      function rangeEntry(name, axis) {
        const pure = rangeSpec(axis);
        const rk = axis + ".range";
        return {
          name,
          source: "relayout",
          writeSpec: pure.writeSpec,
          matchesCurrent: pure.matchesCurrent,
          fromRelayout: pure.fromRelayout,
          apply(el2, v) {
            const u = {};
            u[rk] = v;
            u[axis + ".autorange"] = false;
            return mutate(() => Plotly.relayout(el2, u));
          },
          applyDeferred(el2, spec2) {
            const ax = spec2.layout && spec2.layout[axis];
            const sr = ax && ax.range;
            const u = {};
            if (sr != null) {
              u[rk] = sr;
              u[axis + ".autorange"] = false;
            } else {
              u[axis + ".autorange"] = true;
            }
            return mutate(() => Plotly.relayout(el2, u));
          }
        };
      }
      function scalarEntry(name) {
        const pure = scalarSpec(name);
        return {
          name,
          source: "relayout",
          writeSpec: pure.writeSpec,
          matchesCurrent: pure.matchesCurrent,
          fromRelayout: pure.fromRelayout,
          apply(el2, v) {
            const u = {};
            u[name] = v;
            return mutate(() => Plotly.relayout(el2, u));
          },
          applyDeferred(el2, spec2) {
            const sv = spec2.layout ? spec2.layout[name] : void 0;
            const u = {};
            u[name] = sv == null ? null : sv;
            return mutate(() => Plotly.relayout(el2, u));
          }
        };
      }
      function selectionEntry() {
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
            const ids = v == null ? [] : [].concat(v);
            const g = idsToIndices(el2.data, ids);
            const empty = ids.length === 0;
            const sel = el2.data.map((_, i) => empty ? null : g[i] || []);
            return mutate(
              () => Plotly.relayout(el2, { selections: null }).then(
                () => Plotly.restyle(el2, { selectedpoints: sel })
              )
            );
          },
          applyDeferred(el2) {
            const sel = el2.data.map(() => null);
            return mutate(
              () => Plotly.relayout(el2, { selections: null }).then(
                () => Plotly.restyle(el2, { selectedpoints: sel })
              )
            );
          }
        };
      }
      function visibilityEntry() {
        const pure = visibilitySpec();
        return {
          name: "trace_visibility",
          source: "restyle",
          writeSpec: pure.writeSpec,
          matchesCurrent: pure.matchesCurrent,
          apply(el2, v) {
            const vm = v;
            const idx = [];
            const vals = [];
            el2.data.forEach((tr, i) => {
              if (tr.name != null && vm[tr.name] !== void 0) {
                idx.push(i);
                vals.push(typedVisibility(vm[tr.name]));
              }
            });
            if (!idx.length) return Promise.resolve();
            return mutate(() => Plotly.restyle(el2, { visible: vals }, idx));
          },
          applyDeferred() {
            return Promise.resolve();
          }
        };
      }
      function makeEntry(name) {
        const m = name.match(/^([xy]axis\d*)_range$/);
        if (m) return rangeEntry(name, m[1]);
        if (name === "dragmode" || name === "hovermode") return scalarEntry(name);
        if (name === "selected_ids") return selectionEntry();
        if (name === "trace_visibility") return visibilityEntry();
        return null;
      }
      const entries = [];
      Object.keys(props).forEach((key) => {
        const e = makeEntry(key);
        if (e) {
          entries.push(e);
          state[key] = props[key];
        }
      });
      function merge() {
        const s = deepCopy(spec);
        if (!s.layout) s.layout = {};
        if (s.layout.uirevision == null) s.layout.uirevision = "irid";
        entries.forEach((entry) => {
          const v = state[entry.name];
          if (v != null) entry.writeSpec(s, v);
        });
        return s;
      }
      function render() {
        return mutate(() => {
          const m = merge();
          return Plotly.react(gd, m.data, m.layout, m.config || {});
        }).then(() => {
          ready = true;
          if (!listenersAttached) {
            attachListeners();
            listenersAttached = true;
          }
          gd.setAttribute("data-irid-plotly-ready", "1");
        });
      }
      function attachListeners() {
        gd.on("plotly_relayout", (payload) => {
          if (applying()) return;
          const keys = Object.keys(payload);
          if (!keys.length) return;
          sendEvent("relayout", payload);
          entries.forEach((entry) => {
            if (entry.source !== "relayout" || !entry.fromRelayout) return;
            const v = entry.fromRelayout(payload);
            if (v !== void 0) setProp(entry.name, v);
          });
        });
        gd.on("plotly_selected", (e) => {
          if (applying()) return;
          setProp("selected_ids", idsFromPoints(gd, e && e.points));
        });
        gd.on("plotly_selecting", (e) => {
          if (applying()) return;
          sendEvent("selecting", slimPoints(e));
        });
        gd.on("plotly_deselect", () => {
          if (applying()) return;
          setProp("selected_ids", null);
          sendEvent("deselect", {});
        });
        gd.on("plotly_restyle", () => {
          if (applying()) return;
          setProp("trace_visibility", readVisibility(gd));
        });
        gd.on("plotly_click", (e) => {
          sendEvent("click", slimPoints(e));
        });
        gd.on("plotly_hover", (e) => {
          sendEvent("hover", slimPoints(e));
        });
        gd.on("plotly_unhover", () => {
          sendEvent("unhover", {});
        });
        gd.on("plotly_doubleclick", () => {
          sendEvent("doubleclick", {});
        });
        gd.on("plotly_legendclick", (e) => {
          sendEvent("legend-click", { curveNumber: e.curveNumber });
          return true;
        });
        gd.on("plotly_legenddoubleclick", (e) => {
          sendEvent("legend-doubleclick", { curveNumber: e.curveNumber });
          return true;
        });
        gd.on("plotly_clickannotation", (e) => {
          sendEvent("click-annotation", { index: e.index, annotation: e.annotation });
        });
        gd.on("plotly_sunburstclick", (e) => {
          sendEvent("sunburst-click", slimPoints(e));
        });
      }
      render();
      return {
        update(values) {
          const reactNeeded = "spec" in values;
          if (reactNeeded) spec = JSON.parse(values.spec);
          entries.forEach((entry) => {
            if (!(entry.name in values)) return;
            const v = values[entry.name];
            state[entry.name] = v;
            if (reactNeeded || !ready) return;
            if (v == null) entry.applyDeferred(gd, spec);
            else if (!entry.matchesCurrent(gd, v)) entry.apply(gd, v);
          });
          if (reactNeeded || !ready) render();
        },
        destroy() {
          Plotly.purge(gd);
        }
      };
    }
  );
})();
//# sourceMappingURL=plotly-irid.js.map

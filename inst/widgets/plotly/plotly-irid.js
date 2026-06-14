// irid-plotly widget factory
//
// Registers `irid.defineWidget("plotly", ...)`. Owns the Plotly.react /
// Plotly.relayout / Plotly.restyle / Plotly.purge glue and its own mirror of
// the R-side translation table that maps each named state arg to a spec path
// and a source event.
//
// Load order: irid.js (which defines window.irid) is on the page already;
// this script ships as a widget dep and runs at init time. The pendingInits
// buffer in irid.js absorbs any factory-vs-init race regardless.

(function () {
  if (!window.irid || typeof window.irid.defineWidget !== "function") return;

  // --- small helpers (module scope; no closure deps) ----------------------

  function deepCopy(o) { return JSON.parse(JSON.stringify(o)); }

  function approxEq(a, b) {
    if (a === b) return true;
    if (typeof a !== "number" || typeof b !== "number") return false;
    return Math.abs(a - b) < 1e-6 * (Math.abs(a) + Math.abs(b) + 1);
  }

  // plotly point objects reference data/fullData (circular, huge) — never let
  // those reach Shiny.setInputValue's JSON.stringify. Project to the fields a
  // handler actually wants.
  function slimPoints(e) {
    if (!e || !e.points) return { points: [] };
    return {
      points: e.points.map(function (p) {
        return {
          curveNumber: p.curveNumber,
          pointNumber: p.pointNumber,
          x: p.x, y: p.y, z: p.z,
          text: p.text, customdata: p.customdata
        };
      })
    };
  }

  // selection canonical value: columnar { curve:[...], point:[...] }, 1-based.
  function pointsToFrame(points) {
    if (!points || !points.length) return null;
    var curve = [], point = [];
    points.forEach(function (p) {
      curve.push(p.curveNumber + 1);
      point.push(p.pointNumber + 1);
    });
    return { curve: curve, point: point };
  }

  // 1-based columnar { curve, point } -> { traceIndex -> [0-based points] }.
  // Tolerates scalars (jsonlite auto_unbox collapses length-1 arrays).
  function groupSelection(v) {
    var g = {};
    if (!v || v.curve == null || v.point == null) return g;
    var curves = [].concat(v.curve), points = [].concat(v.point);
    for (var i = 0; i < curves.length; i++) {
      var c = curves[i] - 1;
      if (!g[c]) g[c] = [];
      g[c].push(points[i] - 1);
    }
    return g;
  }

  function typedVisibility(s) {
    if (s === "true" || s === true) return true;
    if (s === "false" || s === false) return false;
    return s; // "legendonly"
  }
  function stringVisibility(v) {
    if (v === false) return "false";
    if (v === "legendonly") return "legendonly";
    return "true"; // true or undefined
  }
  function readVisibility(el) {
    return el.data.map(function (tr) { return stringVisibility(tr.visible); });
  }

  // --- factory ------------------------------------------------------------

  // plotly-main and this factory ship in the same init message, so Plotly
  // may not have executed yet when the factory first runs. Gate every Plotly
  // call behind this.
  function whenPlotly() {
    if (window.Plotly) return Promise.resolve();
    return new Promise(function (resolve) {
      var t = setInterval(function () {
        if (window.Plotly) { clearInterval(t); resolve(); }
      }, 30);
    });
  }

  window.irid.defineWidget("plotly", function (el, props, sendEvent, setProp) {
    var applying = false;              // raised around our own graph mutations
    var listenersAttached = false;
    var ready = false;                 // first render committed?
    var spec = JSON.parse(props.spec);
    var state = {};

    // every programmatic mutation runs through this guard. react() is silent
    // (no plotly_relayout); relayout()/restyle() echo a synchronous
    // plotly_relayout that the listener must ignore. The echo fires before the
    // returned promise resolves, so clearing in .then() is always in time.
    function mutate(fn) {
      applying = true;
      var p;
      try { p = fn(); } catch (err) { applying = false; throw err; }
      return Promise.resolve(p).then(
        function (r) { applying = false; return r; },
        function (err) { applying = false; throw err; }
      );
    }

    // ---- translation-table entries, built from the state prop keys --------
    // Each entry: { name, source, writeSpec(spec,v), apply(el,v),
    //   applyDeferred(el,spec), matchesCurrent(el,v), fromRelayout(payload) }.

    function rangeEntry(name, axis) {
      var rk = axis + ".range";
      return {
        name: name, source: "relayout",
        writeSpec: function (s, v) {
          if (!s.layout[axis]) s.layout[axis] = {};
          s.layout[axis].range = v;
          s.layout[axis].autorange = false;
        },
        apply: function (el, v) {
          var u = {}; u[rk] = v; u[axis + ".autorange"] = false;
          return mutate(function () { return Plotly.relayout(el, u); });
        },
        applyDeferred: function (el, spec) {
          var sr = spec.layout && spec.layout[axis] && spec.layout[axis].range;
          var u = {};
          if (sr != null) { u[rk] = sr; u[axis + ".autorange"] = false; }
          else { u[axis + ".autorange"] = true; }
          return mutate(function () { return Plotly.relayout(el, u); });
        },
        matchesCurrent: function (el, v) {
          var cur = el.layout && el.layout[axis] && el.layout[axis].range;
          return !!cur && approxEq(cur[0], v[0]) && approxEq(cur[1], v[1]);
        },
        fromRelayout: function (p) {
          if (p[rk] !== undefined) return p[rk];           // whole-array
          var lo = p[axis + ".range[0]"], hi = p[axis + ".range[1]"];
          if (lo !== undefined && hi !== undefined) return [lo, hi]; // split
          if (p[axis + ".autorange"] === true) return null;          // reset
          return undefined;                                          // abstain
        }
      };
    }

    function scalarEntry(name) {
      return {
        name: name, source: "relayout",
        writeSpec: function (s, v) { s.layout[name] = v; },
        apply: function (el, v) {
          var u = {}; u[name] = v;
          return mutate(function () { return Plotly.relayout(el, u); });
        },
        applyDeferred: function (el, spec) {
          var sv = spec.layout ? spec.layout[name] : undefined;
          var u = {}; u[name] = (sv == null ? null : sv);
          return mutate(function () { return Plotly.relayout(el, u); });
        },
        matchesCurrent: function (el, v) {
          return !!el.layout && el.layout[name] === v;
        },
        fromRelayout: function (p) { return p[name]; }  // undefined if absent
      };
    }

    function selectionEntry() {
      return {
        name: "selected_points", source: "selected",
        writeSpec: function (s, v) {
          var g = groupSelection(v);
          s.data.forEach(function (tr, i) { if (g[i]) tr.selectedpoints = g[i]; });
        },
        // Both set and clear must drop the active drag selection FIRST: while
        // one is active plotly owns selectedpoints, so a bare restyle is a
        // silent no-op (and a leftover outline rectangle stays on screen). So
        // clear layout.selections, THEN restyle the per-point dimming to the
        // new value (or null). matchesCurrent (below) is what keeps a user's
        // OWN fresh marquee from being wiped — the drag's echo matches current
        // state and is skipped, so only a *different* (programmatic) selection
        // reaches here and clears the stale outline.
        apply: function (el, v) {
          var g = groupSelection(v);
          var sel = el.data.map(function (_, i) { return g[i] || []; });
          return mutate(function () {
            return Plotly.relayout(el, { selections: null }).then(function () {
              return Plotly.restyle(el, { selectedpoints: sel });
            });
          });
        },
        applyDeferred: function (el) {
          var sel = el.data.map(function () { return null; });
          return mutate(function () {
            return Plotly.relayout(el, { selections: null }).then(function () {
              return Plotly.restyle(el, { selectedpoints: sel });
            });
          });
        },
        // True when the graph ALREADY shows exactly this selection — the echo
        // of a user's own drag (plotly set selectedpoints from it). Skipping it
        // leaves their marquee intact; a mismatch (programmatic set) falls
        // through to apply, which clears the stale outline first.
        matchesCurrent: function (el, v) {
          var g = groupSelection(v);
          return el.data.every(function (tr, i) {
            var want = g[i] || [];
            var have = tr.selectedpoints || [];
            if (want.length !== have.length) return false;
            var hs = {};
            have.forEach(function (x) { hs[x] = true; });
            return want.every(function (x) { return hs[x]; });
          });
        }
      };
    }

    function visibilityEntry() {
      return {
        name: "trace_visibility", source: "restyle",
        writeSpec: function (s, v) {
          var vis = [].concat(v);
          s.data.forEach(function (tr, i) {
            if (i < vis.length) tr.visible = typedVisibility(vis[i]);
          });
        },
        apply: function (el, v) {
          var vis = [].concat(v).map(typedVisibility);
          return mutate(function () { return Plotly.restyle(el, { visible: vis }); });
        },
        applyDeferred: function () { return Promise.resolve(); },
        matchesCurrent: function (el, v) {
          var vis = [].concat(v);
          return el.data.every(function (tr, i) {
            return stringVisibility(tr.visible) === String(vis[i]);
          });
        }
      };
    }

    function makeEntry(name) {
      var m = name.match(/^([xy]axis\d*)_range$/);
      if (m) return rangeEntry(name, m[1]);
      if (name === "dragmode" || name === "hovermode") return scalarEntry(name);
      if (name === "selected_points") return selectionEntry();
      if (name === "trace_visibility") return visibilityEntry();
      return null; // unknown — R side already rejected these; ignore defensively
    }

    // Build entries from the explicit bound-key list, NOT from Object.keys
    // (props): a NULL-initialized state arg is dropped from the init props
    // object, so its key would otherwise be invisible here. Its initial value
    // is whatever survived in props (or null if dropped).
    var stateKeys = [].concat(props.__irid_state_keys || []);
    var entries = [];
    stateKeys.forEach(function (key) {
      var e = makeEntry(key);
      if (e) { entries.push(e); state[key] = (key in props) ? props[key] : null; }
    });

    // ---- render ------------------------------------------------------------

    function merge() {
      var s = deepCopy(spec);
      if (!s.layout) s.layout = {};
      if (s.layout.uirevision == null) s.layout.uirevision = "irid";
      entries.forEach(function (entry) {
        var v = state[entry.name];
        if (v != null) entry.writeSpec(s, v);
      });
      return s;
    }

    function render() {
      return whenPlotly().then(function () {
        return mutate(function () {
          var m = merge();
          return Plotly.react(el, m.data, m.layout, m.config || {});
        });
      }).then(function () {
        ready = true;
        if (!listenersAttached) { attachListeners(); listenersAttached = true; }
      });
    }

    function attachListeners() {
      el.on("plotly_relayout", function (payload) {
        if (applying) return;            // our own relayout/restyle echo
        // Emit the raw escape-hatch notification FIRST, then the prop writes.
        // setProp and sendEvent share one per-element sequence counter; if the
        // notification went last it would bump the sequence past the prop
        // writes, and each prop's snap-back echo (tagged with the prop's lower
        // sequence) would be gated out as stale. Notifying first lets every
        // prop carry the gesture's highest sequence, so a rejected write snaps
        // back. (When onRelayout is unbound, sendEvent is a no-op that does not
        // touch the sequence.)
        sendEvent("relayout", payload);  // raw escape hatch (no-op if unbound)
        entries.forEach(function (entry) {
          if (entry.source !== "relayout") return;
          var v = entry.fromRelayout(payload);
          if (v !== undefined) setProp(entry.name, v);  // value | null
        });
      });
      el.on("plotly_selected", function (e) {
        if (applying) return;            // echo from our own react/restyle
        setProp("selected_points", pointsToFrame(e && e.points));
      });
      el.on("plotly_selecting", function (e) {
        if (applying) return;
        sendEvent("selecting", slimPoints(e));
      });
      el.on("plotly_deselect", function () {
        if (applying) return;            // a data-change react() deselects —
        // that is our mutation, not the user clearing; do not write back.
        setProp("selected_points", null);
        sendEvent("deselect", {});
      });
      el.on("plotly_restyle", function () {
        if (applying) return;
        setProp("trace_visibility", readVisibility(el));
      });
      el.on("plotly_click", function (e) { sendEvent("click", slimPoints(e)); });
      el.on("plotly_hover", function (e) { sendEvent("hover", slimPoints(e)); });
      el.on("plotly_unhover", function () { sendEvent("unhover", {}); });
      el.on("plotly_doubleclick", function () { sendEvent("doubleclick", {}); });
      el.on("plotly_legendclick", function (e) {
        sendEvent("legend-click", { curveNumber: e.curveNumber }); return true;
      });
      el.on("plotly_legenddoubleclick", function (e) {
        sendEvent("legend-doubleclick", { curveNumber: e.curveNumber }); return true;
      });
      el.on("plotly_clickannotation", function (e) {
        sendEvent("click-annotation", { index: e.index, annotation: e.annotation });
      });
      el.on("plotly_sunburstclick", function (e) { sendEvent("sunburst-click", slimPoints(e)); });
    }

    render();

    // ---- server -> client batch -------------------------------------------

    return {
      update: function (values) {
        var reactNeeded = ("spec" in values);
        if (reactNeeded) spec = JSON.parse(values.spec);
        entries.forEach(function (entry) {
          if (!(entry.name in values)) return;
          var v = values[entry.name];
          state[entry.name] = v;
          // Before the first render commits (or when a spec change is in the
          // same batch), the upcoming render() folds in this state — no
          // targeted apply needed.
          if (reactNeeded || !ready) return;
          if (v == null) entry.applyDeferred(el, spec);             // reset
          else if (!entry.matchesCurrent(el, v)) entry.apply(el, v); // snap/apply
        });
        if (reactNeeded || !ready) render(); // one redraw for the whole batch
      },
      destroy: function () { Plotly.purge(el); }
    };
  });
})();

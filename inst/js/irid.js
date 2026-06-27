"use strict";
(() => {
  // src/core/stale.ts
  var staleTimeout = null;
  var staleShowTimerId = null;
  var staleClearTimerId = null;
  var STALE_CLEAR_DELAY = 100;
  function setStaleTimeout(value) {
    staleTimeout = value;
  }
  function markStale() {
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
    document.documentElement.classList.add("irid-stale");
  }
  function clearStale() {
    if (staleShowTimerId !== null) {
      clearTimeout(staleShowTimerId);
      staleShowTimerId = null;
    }
    if (staleClearTimerId === null) {
      staleClearTimerId = setTimeout(() => {
        staleClearTimerId = null;
        document.documentElement.classList.remove("irid-stale");
      }, STALE_CLEAR_DELAY);
    }
  }
  function onEventSent() {
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
    if (staleTimeout !== null && staleShowTimerId === null && !document.documentElement.classList.contains("irid-stale")) {
      staleShowTimerId = setTimeout(markStale, staleTimeout);
    }
  }
  $(document).on("shiny:busy", () => {
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
  });
  $(document).on("shiny:idle", () => {
    clearStale();
  });

  // src/core/seq.ts
  var sequences = {};
  function isStaleEcho(gate, seqs) {
    if (!gate) return false;
    const latest = seqs[gate.channel];
    return latest !== void 0 && gate.seq < latest;
  }
  function nextSequence(seqs, channel) {
    if (!seqs[channel]) seqs[channel] = 0;
    return ++seqs[channel];
  }

  // src/core/payload.ts
  function attachPayloadMeta(data, id, channel) {
    return { id, seq: nextSequence(sequences, channel), data };
  }
  function buildPayload(e, el, id, channel) {
    const data = {};
    for (const key in e) {
      try {
        const val = e[key];
        if (typeof val === "string" || typeof val === "number" || typeof val === "boolean") {
          data[key] = val;
        }
      } catch {
      }
    }
    const input = el;
    data.value = input.value;
    if (typeof input.valueAsNumber === "number") {
      data.valueAsNumber = input.valueAsNumber;
    }
    if (typeof input.checked === "boolean") {
      data.checked = input.checked;
    }
    return attachPayloadMeta(data, id, channel);
  }

  // src/core/ratelimit.ts
  var managed = {};
  var widgetStreams = {};
  var elementQueues = {};
  var idleListenerActive = false;
  function sendPayload(inputId, payload) {
    Shiny.setInputValue(inputId, payload, { priority: "event" });
    onEventSent();
  }
  function onShinyIdle() {
    idleListenerActive = false;
    let anySent = false;
    for (const inputId in managed) {
      const s = managed[inputId];
      if (s.serverBusy) {
        s.serverBusy = false;
        if (s.maybeSend) s.maybeSend();
        if (s.serverBusy) anySent = true;
      }
    }
    if (anySent) {
      $(document).one("shiny:idle", onShinyIdle);
      idleListenerActive = true;
    }
  }
  function ensureIdleListener() {
    if (!idleListenerActive) {
      $(document).one("shiny:idle", onShinyIdle);
      idleListenerActive = true;
    }
  }
  function queueJoin(s) {
    const q = elementQueues[s.id] || (elementQueues[s.id] = []);
    if (q.indexOf(s) === -1) q.push(s);
  }
  function queueReady(s, payload) {
    s.qPayload = payload;
    s.qReady = true;
    queueJoin(s);
    drainQueue(s.id);
  }
  function drainQueue(elId) {
    const q = elementQueues[elId];
    if (!q) return;
    while (q.length) {
      const head = q[0];
      if (!head.qReady) {
        let laterReady = false;
        for (let i = 1; i < q.length; i++) {
          if (q[i].qReady) {
            laterReady = true;
            break;
          }
        }
        if (!laterReady) break;
        head.qFlush();
      }
      q.shift();
      const p = head.qPayload;
      head.qPayload = null;
      head.qReady = false;
      if (p !== null && p !== void 0) {
        sendPayload(head.inputId, p);
        if (head.coalesce) {
          head.serverBusy = true;
          ensureIdleListener();
        }
      }
    }
  }
  function compileFilter(opts) {
    if (!opts.filter) return null;
    try {
      return new Function("e", "return (" + opts.filter + ");");
    } catch (err) {
      console.error("irid: invalid event filter expression:", opts.filter, err);
      return null;
    }
  }
  function shouldSkip(el, eventName) {
    const input = el;
    return eventName === "change" && el.tagName === "INPUT" && input.type === "radio" && !input.checked;
  }
  function attachListener(el, msg, dispatch) {
    const opts = msg.domOpts;
    const filter = compileFilter(opts);
    el.addEventListener(
      msg.event,
      (e) => {
        if (shouldSkip(el, msg.event)) return;
        if (filter && !filter(e)) return;
        if (opts.preventDefault) e.preventDefault();
        if (opts.stopPropagation) e.stopPropagation();
        dispatch(buildPayload(e, el, msg.id, msg.channel));
      },
      { capture: opts.capture, passive: opts.passive }
    );
  }
  function attachClientOnlyListener(el, msg) {
    const opts = msg.domOpts;
    const filter = compileFilter(opts);
    el.addEventListener(
      msg.event,
      (e) => {
        if (shouldSkip(el, msg.event)) return;
        if (filter && !filter(e)) return;
        if (opts.preventDefault) e.preventDefault();
        if (opts.stopPropagation) e.stopPropagation();
      },
      { capture: opts.capture, passive: opts.passive }
    );
  }
  function setupThrottle(el, msg, ms, leading) {
    const s = {
      id: msg.id,
      inputId: msg.channel,
      payload: null,
      timerRunning: false,
      timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      leading,
      qPayload: null,
      qReady: false,
      maybeSend: () => {
      },
      dispatch: () => {
      },
      qFlush: () => {
      }
    };
    function startCooldown() {
      s.timerRunning = true;
      setTimeout(() => {
        s.timerRunning = false;
        s.timerReady = true;
        s.maybeSend();
      }, ms);
    }
    s.maybeSend = () => {
      if (s.coalesce && s.serverBusy) return;
      if (!s.timerReady) return;
      if (s.payload === null) return;
      const p = s.payload;
      s.payload = null;
      s.timerReady = false;
      queueReady(s, p);
      startCooldown();
    };
    s.dispatch = (payload) => {
      s.payload = payload;
      queueJoin(s);
      if (s.timerRunning) return;
      if (s.leading && !(s.coalesce && s.serverBusy)) {
        const p = s.payload;
        s.payload = null;
        queueReady(s, p);
        startCooldown();
      } else {
        startCooldown();
      }
    };
    s.qFlush = () => {
      s.qPayload = s.payload;
      s.payload = null;
      s.timerReady = false;
      s.qReady = true;
    };
    managed[msg.channel] = s;
    if (msg.source !== "widget" && el) attachListener(el, msg, s.dispatch);
    return s;
  }
  function setupDebounce(el, msg, ms) {
    const s = {
      id: msg.id,
      inputId: msg.channel,
      payload: null,
      timerId: null,
      timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      qPayload: null,
      qReady: false,
      maybeSend: () => {
      },
      dispatch: () => {
      },
      qFlush: () => {
      }
    };
    s.maybeSend = () => {
      if (s.coalesce && s.serverBusy) return;
      if (!s.timerReady) return;
      if (s.payload === null) return;
      const p = s.payload;
      s.payload = null;
      s.timerReady = false;
      queueReady(s, p);
    };
    s.dispatch = (payload) => {
      s.payload = payload;
      s.timerReady = false;
      queueJoin(s);
      if (s.timerId !== null && s.timerId !== void 0) clearTimeout(s.timerId);
      s.timerId = setTimeout(() => {
        s.timerId = null;
        s.timerReady = true;
        s.maybeSend();
      }, ms);
    };
    s.qFlush = () => {
      if (s.timerId !== null && s.timerId !== void 0) {
        clearTimeout(s.timerId);
        s.timerId = null;
      }
      s.timerReady = false;
      s.qPayload = s.payload;
      s.payload = null;
      s.qReady = true;
    };
    managed[msg.channel] = s;
    if (msg.source !== "widget" && el) attachListener(el, msg, s.dispatch);
    return s;
  }
  function setupImmediate(el, msg) {
    const s = {
      id: msg.id,
      inputId: msg.channel,
      payload: null,
      serverBusy: false,
      coalesce: msg.coalesce,
      qPayload: null,
      qReady: false,
      maybeSend: () => {
      },
      dispatch: () => {
      },
      qFlush: () => {
      }
    };
    s.maybeSend = () => {
      if (s.coalesce && s.serverBusy) return;
      if (s.payload === null) return;
      const p = s.payload;
      s.payload = null;
      queueReady(s, p);
    };
    s.dispatch = (payload) => {
      s.payload = payload;
      queueJoin(s);
      s.maybeSend();
    };
    s.qFlush = () => {
      s.qPayload = s.payload;
      s.payload = null;
      s.qReady = true;
    };
    managed[msg.channel] = s;
    if (msg.source !== "widget" && el) attachListener(el, msg, s.dispatch);
    return s;
  }
  function pushManaged(s, id, payload) {
    if (!s) return;
    const p = attachPayloadMeta(Object.assign({}, payload || {}), id, s.inputId);
    s.dispatch(p);
  }
  function sendWidgetEvent(id, event, payload) {
    pushManaged(widgetStreams["event:" + id + ":" + event], id, payload || {});
  }
  function setWidgetProp(id, key, value) {
    pushManaged(widgetStreams["prop:" + id + ":" + key], id, { value });
  }

  // src/core/widgets.ts
  var defined = /* @__PURE__ */ new Map();
  var pendingInits = {};
  var widgets = {};
  function mountWidget(id, name, props, factory) {
    if (widgets[id]) return;
    const el = document.getElementById(id);
    if (!el) {
      console.warn("irid: widget container not found for id=" + id);
      return;
    }
    const sendEvent = (event, payload) => {
      sendWidgetEvent(id, event, payload);
    };
    const setProp = (key, value) => {
      setWidgetProp(id, key, value);
    };
    const entry = {
      handle: null,
      name,
      pending: null,
      destroyed: false
    };
    widgets[id] = entry;
    function commit(handle) {
      const h = handle || {};
      if (entry.destroyed || widgets[id] !== entry) {
        if (typeof h.destroy === "function") {
          try {
            h.destroy();
          } catch (e) {
            console.error(e);
          }
        }
        return;
      }
      entry.handle = h;
      if (entry.pending) {
        if (typeof h.update === "function") h.update(entry.pending);
        entry.pending = null;
      }
    }
    let result;
    try {
      result = factory(el, props, sendEvent, setProp);
    } catch (e) {
      console.error("irid: widget factory threw for " + name, e);
      if (widgets[id] === entry) delete widgets[id];
      return;
    }
    if (result && typeof result.then === "function") {
      result.then(commit, (err) => {
        console.error("irid: widget factory failed for " + name, err);
        if (widgets[id] === entry) delete widgets[id];
      });
    } else {
      commit(result);
    }
  }
  function destroyWidget(id) {
    const w = widgets[id];
    if (!w) return;
    w.destroyed = true;
    if (w.handle && typeof w.handle.destroy === "function") {
      try {
        w.handle.destroy();
      } catch (e) {
        console.error(e);
      }
    }
    delete widgets[id];
  }
  function destroyWidgetsIn(root) {
    if (root.nodeType === 1 && root.hasAttribute("data-irid-widget")) {
      destroyWidget(root.id);
    }
    if (typeof root.querySelectorAll === "function") {
      const els = root.querySelectorAll("[data-irid-widget]");
      for (let i = 0; i < els.length; i++) destroyWidget(els[i].id);
    }
  }
  function defineWidget(name, factory) {
    defined.set(name, factory);
    const queue = pendingInits[name];
    if (queue) {
      delete pendingInits[name];
      queue.forEach((init) => {
        mountWidget(init.id, name, init.props, factory);
      });
    }
  }
  function handleWidgetInit(msg) {
    if (widgets[msg.id]) return;
    const factory = defined.get(msg.name);
    if (!factory) {
      if (!pendingInits[msg.name]) pendingInits[msg.name] = [];
      pendingInits[msg.name].push({ id: msg.id, props: msg.props });
      return;
    }
    mountWidget(msg.id, msg.name, msg.props, factory);
  }

  // src/core/anchors.ts
  var anchors = /* @__PURE__ */ new Map();
  var ANCHOR_RE = /^irid:(s|e):(.+)$/;
  function indexAnchors(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    const starts = {};
    let node;
    while (node = walker.nextNode()) {
      const comment = node;
      const m = comment.data.match(ANCHOR_RE);
      if (!m) continue;
      const kind = m[1];
      const id = m[2];
      if (kind === "s") {
        starts[id] = comment;
      } else if (starts[id]) {
        anchors.set(id, { start: starts[id], end: comment });
        delete starts[id];
      }
    }
  }
  function unregisterAnchorsIn(root) {
    if (root.nodeType === 8) {
      const m = root.data.match(ANCHOR_RE);
      if (m) anchors.delete(m[2]);
      return;
    }
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    let n;
    while (n = walker.nextNode()) {
      const m2 = n.data.match(ANCHOR_RE);
      if (m2) anchors.delete(m2[2]);
    }
  }
  function parseFragment(html, contextNode) {
    const range = document.createRange();
    range.selectNodeContents(contextNode);
    return range.createContextualFragment(html);
  }
  function detachRange(startNode, endNode) {
    const frag = document.createDocumentFragment();
    let n = startNode;
    while (n && n !== endNode) {
      const next = n.nextSibling;
      if (n.nodeType === 1) {
        destroyWidgetsIn(n);
        Shiny.unbindAll(n);
      }
      frag.appendChild(n);
      n = next;
    }
    frag.appendChild(endNode);
    return frag;
  }
  function lookupAnchors(id) {
    const a = anchors.get(id);
    if (a) return a;
    indexAnchors(document.body);
    return anchors.get(id);
  }

  // src/core/handlers.ts
  var PROP_ATTRS = {
    value: true,
    disabled: true,
    checked: true,
    innerHTML: true
  };
  var eventsRegistered = /* @__PURE__ */ new Set();
  function registerHandlers() {
    Shiny.addCustomMessageHandler("irid-config", (msg) => {
      setStaleTimeout(msg.staleTimeout);
    });
    Shiny.addCustomMessageHandler("irid-attr", (msg) => {
      if (msg.target === "widget") {
        const w = widgets[msg.id];
        if (!w) return;
        let values = msg.values;
        if (msg.valueGates) {
          const kept = {};
          let any = false;
          for (const k in values) {
            if (isStaleEcho(msg.valueGates[k], sequences)) continue;
            kept[k] = values[k];
            any = true;
          }
          if (!any) return;
          values = kept;
        }
        if (w.handle) {
          if (typeof w.handle.update === "function") w.handle.update(values);
        } else {
          w.pending = Object.assign(w.pending || {}, values);
        }
        return;
      }
      if (msg.target === "text") {
        const a = lookupAnchors(msg.id);
        if (!a) return;
        const parent = a.start.parentNode;
        let n = a.start.nextSibling;
        while (n && n !== a.end) {
          const next = n.nextSibling;
          if (n.nodeType === 1) Shiny.unbindAll(n);
          parent.removeChild(n);
          n = next;
        }
        if (msg.value !== "") {
          parent.insertBefore(document.createTextNode(msg.value), a.end);
        }
        return;
      }
      if (isStaleEcho(msg.gate, sequences)) return;
      const el = document.getElementById(msg.id);
      if (!el) return;
      if (msg.attr === "value" && document.activeElement === el && el.value === msg.value) {
        return;
      }
      if (PROP_ATTRS[msg.attr]) {
        el[msg.attr] = msg.value;
      } else if (msg.value === false || msg.value === null) {
        el.removeAttribute(msg.attr);
      } else if (msg.attr === "textContent") {
        el.textContent = msg.value;
      } else {
        el.setAttribute(msg.attr, msg.value);
      }
    });
    Shiny.addCustomMessageHandler("irid-mutate", (msg) => {
      const a = lookupAnchors(msg.id);
      if (!a) return;
      const parent = a.start.parentNode;
      if (msg.removes) {
        msg.removes.forEach((childId) => {
          const child = anchors.get(childId);
          if (!child) return;
          const detached = detachRange(child.start, child.end);
          unregisterAnchorsIn(detached);
        });
      }
      if (msg.inserts) {
        msg.inserts.forEach((html) => {
          const fragment = parseFragment(html, parent);
          indexAnchors(fragment);
          parent.insertBefore(fragment, a.end);
        });
      }
      if (msg.order) {
        msg.order.forEach((childId) => {
          const child = anchors.get(childId);
          if (!child) return;
          const frag = document.createDocumentFragment();
          let node = child.start;
          while (node && node !== child.end) {
            const next = node.nextSibling;
            frag.appendChild(node);
            node = next;
          }
          frag.appendChild(child.end);
          parent.insertBefore(frag, a.end);
        });
      }
      setTimeout(() => {
        Shiny.bindAll(parent);
      }, 0);
    });
    Shiny.addCustomMessageHandler("irid-events", (msgs) => {
      msgs.forEach((msg) => {
        const key = msg.channel;
        if (eventsRegistered.has(key)) return;
        const el = document.getElementById(msg.id);
        if (msg.source !== "widget" && !el) return;
        eventsRegistered.add(key);
        if (msg.source === "dom" && msg.clientOnly) {
          attachClientOnlyListener(el, msg);
          return;
        }
        if (msg.timing.mode === "throttle") {
          setupThrottle(el, msg, msg.timing.ms, msg.timing.leading);
        } else if (msg.timing.mode === "debounce") {
          setupDebounce(el, msg, msg.timing.ms);
        } else {
          setupImmediate(el, msg);
        }
        if (msg.source === "widget") {
          widgetStreams[`${msg.kind}:${msg.id}:${msg.event}`] = managed[msg.channel];
        }
      });
    });
    Shiny.addCustomMessageHandler(
      "irid-widget-init",
      (msg) => {
        handleWidgetInit(msg);
      }
    );
    Shiny.addCustomMessageHandler("irid-ready", (msg) => {
      var _a;
      window.__iridReady = true;
      document.dispatchEvent(
        new CustomEvent("irid:ready", { detail: { id: (_a = msg == null ? void 0 : msg.output) != null ? _a : null } })
      );
    });
  }

  // src/core/index.ts
  var irid = { defineWidget };
  window.irid = irid;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      indexAnchors(document.body);
    });
  } else {
    indexAnchors(document.body);
  }
  registerHandlers();
})();
//# sourceMappingURL=irid.js.map

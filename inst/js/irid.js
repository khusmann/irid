(function() {
  var eventsRegistered = new Set();  // `${id}:${event}` keys — once-per-pair listener install
  var sequences = {};  // element id -> latest sent sequence number
  var PROP_ATTRS = { value: true, disabled: true, checked: true, innerHTML: true };
  var anchors = new Map();  // id -> { start: CommentNode, end: CommentNode }
  var ANCHOR_RE = /^irid:(s|e):(.+)$/;
  var staleTimeout = null;  // ms before showing stale indicator (null = disabled)
  var staleShowTimerId = null;
  var staleClearTimerId = null;
  var STALE_CLEAR_DELAY = 100;  // ms to wait after idle before removing overlay

  // --- Widget registry ---
  // `defined` maps a widget registry name to its factory. Inits that
  // arrive before the factory is registered (script load race) are
  // buffered under `pendingInits[name]` and drained in arrival order
  // when defineWidget(name, ...) lands. `widgets` is the live per-id
  // table: `{id -> {handle, name}}` where `handle = {update, destroy}`.
  var defined = new Map();
  var pendingInits = {};
  var widgets = {};

  function markStale() {
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
    document.documentElement.classList.add('irid-stale');
  }

  function clearStale() {
    if (staleShowTimerId !== null) {
      clearTimeout(staleShowTimerId);
      staleShowTimerId = null;
    }
    // Debounce the clear so rapid idle/busy cycles don't flicker
    if (staleClearTimerId === null) {
      staleClearTimerId = setTimeout(function() {
        staleClearTimerId = null;
        document.documentElement.classList.remove('irid-stale');
      }, STALE_CLEAR_DELAY);
    }
  }

  function onEventSent() {
    // Cancel any pending clear — we're busy again
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
    if (staleTimeout !== null && staleShowTimerId === null &&
        !document.documentElement.classList.contains('irid-stale')) {
      staleShowTimerId = setTimeout(markStale, staleTimeout);
    }
  }

  // Cancel pending clear if server becomes busy again (e.g. a reactive
  // chain triggers a follow-up flush after the initial idle).
  $(document).on('shiny:busy', function() {
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
  });

  // Clear stale state when server finishes processing
  $(document).on('shiny:idle', function() {
    clearStale();
  });

  // --- Comment-anchor registry ---
  // Control-flow nodes are represented in the DOM as a pair of comment
  // markers (<!--irid:s:ID--> ... <!--irid:e:ID-->) rather than a wrapper
  // element. This keeps them valid inside restricted parents like
  // <select>, <table>, and <ul>. We maintain a Map from id -> {start, end}
  // that we populate on initial load and keep in sync as content is
  // inserted or removed.

  function indexAnchors(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    var starts = {};
    var node;
    while ((node = walker.nextNode())) {
      var m = node.data.match(ANCHOR_RE);
      if (!m) continue;
      var kind = m[1], id = m[2];
      if (kind === 's') {
        starts[id] = node;
      } else if (starts[id]) {
        anchors.set(id, { start: starts[id], end: node });
        delete starts[id];
      }
    }
  }

  function unregisterAnchorsIn(root) {
    // root may be a DocumentFragment, Element, or a detached Comment.
    if (root.nodeType === 8) {
      var m = root.data.match(ANCHOR_RE);
      if (m) anchors.delete(m[2]);
      return;
    }
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    var n;
    while ((n = walker.nextNode())) {
      var m2 = n.data.match(ANCHOR_RE);
      if (m2) anchors.delete(m2[2]);
    }
  }

  // Parse HTML into a fragment using the anchor's parent as the parsing
  // context, so restricted-content elements (<option>, <tr>, etc.) parse
  // correctly.
  function parseFragment(html, contextNode) {
    var range = document.createRange();
    range.selectNodeContents(contextNode);
    return range.createContextualFragment(html);
  }

  // Move the full range [start..end] (inclusive) into a detached
  // DocumentFragment. Runs Shiny.unbindAll on element nodes in the range.
  function detachRange(startNode, endNode) {
    var frag = document.createDocumentFragment();
    var n = startNode;
    while (n && n !== endNode) {
      var next = n.nextSibling;
      if (n.nodeType === 1) {
        // Destroy widget instances first, before unbindAll and before
        // we move the node into a detached fragment — widget destroy()
        // hooks may want intact DOM ancestors.
        destroyWidgetsIn(n);
        Shiny.unbindAll(n);
      }
      frag.appendChild(n);
      n = next;
    }
    frag.appendChild(endNode);
    return frag;
  }

  // Look up anchors with a lazy re-scan fallback. Dynamic content
  // delivered via renderUI/iridOutput (renderIrid) arrives as a Shiny
  // output binding update — not a irid custom message — so we need to
  // index its anchors before the subsequent irid-swap/irid-mutate
  // messages fire.
  function lookupAnchors(id) {
    var a = anchors.get(id);
    if (a) return a;
    indexAnchors(document.body);
    return anchors.get(id);
  }

  // Initial scan — comment anchors in the static page must be registered
  // before any irid-swap/irid-mutate message arrives.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      indexAnchors(document.body);
    });
  } else {
    indexAnchors(document.body);
  }

  Shiny.addCustomMessageHandler('irid-config', function(msg) {
    if (msg.staleTimeout !== undefined && msg.staleTimeout !== null) {
      staleTimeout = msg.staleTimeout;
    } else {
      staleTimeout = null;
    }
  });

  // Dispatch by msg.target:
  //   "text" — replace the content between the comment-anchor pair
  //            `msg.id` with a single text node. Used for reactive text
  //            children, which sit in restricted-content parents
  //            (`<option>`, `<textarea>`, ...) where a `<span>` wrapper
  //            would be stripped by the HTML parser.
  //   "dom"  — set a DOM attribute or property on
  //            `getElementById(msg.id)`. Includes focused-element
  //            optimistic-update gating for `attr === "value"`.
  Shiny.addCustomMessageHandler('irid-attr', function(msg) {
    // Universal stale-echo gate. When the user produces events faster
    // than the server can echo them back, an echo for an earlier value
    // can arrive after newer ones have been sent. `sequences[id]` is
    // bumped in `attachPayloadMeta` on every outbound event, so it
    // moves ahead of an in-flight echo as soon as the user produces
    // another event from the same element. The check is inert when no
    // sequence is present (programmatic updates from a different
    // element) or when sequences hasn't moved past the echo's seq
    // (echo is current).
    if (msg.sequence !== undefined && msg.sequence !== null &&
        sequences[msg.id] !== undefined &&
        msg.sequence < sequences[msg.id]) {
      return;
    }

    if (msg.target === 'widget') {
      // Route to the widget's update hook. Skip if no widget is
      // registered for this id — covers the timing-dependent reorder
      // where an attr message arrives before the matching init
      // (defense in depth; mount sends init before any attr).
      var w = widgets[msg.id];
      if (!w) return;
      if (typeof w.handle.update === 'function') {
        // Always a `values: {attr -> value}` map (one or more keys),
        // coalesced server-side per widget per flush. A single-prop change
        // is just a one-entry map.
        w.handle.update(msg.values);
      }
      return;
    }

    if (msg.target === 'text') {
      var a = lookupAnchors(msg.id);
      if (!a) return;
      var parent = a.start.parentNode;
      var n = a.start.nextSibling;
      while (n && n !== a.end) {
        var next = n.nextSibling;
        if (n.nodeType === 1) Shiny.unbindAll(n);
        parent.removeChild(n);
        n = next;
      }
      var val = msg.value;
      if (val !== null && val !== undefined && val !== '') {
        parent.insertBefore(document.createTextNode(String(val)), a.end);
      }
      return;
    }

    // target === 'dom'
    var el = document.getElementById(msg.id);
    if (!el) return;
    // Cursor-preservation no-op skip — independent of the staleness gate
    // above. Setting `el.value` to its current string would reset the
    // cursor on a focused input, so short-circuit identical writes.
    // The widget path doesn't get a parallel skip here because "current
    // value" is library-specific (CodeMirror's `view.state.doc`, Plotly's
    // layout, etc.); widget authors do the equivalent `value === current`
    // check inside their factory's `update` hook.
    if (msg.attr === 'value' && document.activeElement === el &&
        el.value === msg.value) {
      return;
    }
    if (PROP_ATTRS[msg.attr]) {
      el[msg.attr] = msg.value;
    } else if (msg.value === false || msg.value === null) {
      el.removeAttribute(msg.attr);
    } else {
      if (msg.attr === 'textContent') {
        el.textContent = msg.value;
      } else {
        el.setAttribute(msg.attr, msg.value);
      }
    }
  });

  Shiny.addCustomMessageHandler('irid-swap', function(msg) {
    var a = lookupAnchors(msg.id);
    if (!a) return;
    var parent = a.start.parentNode;

    // Detach everything between start and end (exclusive). unbindAll runs
    // on each removed element inside detachRange.
    var detached = document.createDocumentFragment();
    var n = a.start.nextSibling;
    while (n && n !== a.end) {
      var next = n.nextSibling;
      if (n.nodeType === 1) {
        destroyWidgetsIn(n);
        Shiny.unbindAll(n);
      }
      detached.appendChild(n);
      n = next;
    }
    unregisterAnchorsIn(detached);

    if (msg.html) {
      var fragment = parseFragment(msg.html, parent);
      indexAnchors(fragment);
      parent.insertBefore(fragment, a.end);
    }

    // Defer bindAll so Shiny finishes processing all messages in the
    // current flush before we ask it to discover new output bindings
    setTimeout(function() { Shiny.bindAll(parent); }, 0);
  });

  Shiny.addCustomMessageHandler('irid-mutate', function(msg) {
    var a = lookupAnchors(msg.id);
    if (!a) return;
    var parent = a.start.parentNode;

    // 1. Remove children — each child is itself an anchored range
    if (msg.removes) {
      msg.removes.forEach(function(childId) {
        var child = anchors.get(childId);
        if (!child) return;
        var detached = detachRange(child.start, child.end);
        unregisterAnchorsIn(detached);
      });
    }

    // 2. Insert new children (parsed in the container's parent context,
    // appended immediately before the container's end anchor)
    if (msg.inserts) {
      msg.inserts.forEach(function(html) {
        var fragment = parseFragment(html, parent);
        indexAnchors(fragment);
        parent.insertBefore(fragment, a.end);
      });
    }

    // 3. Reorder children — lift each child's [start..end] range into a
    // fragment, then insert the fragment before the container's end
    // anchor in the desired order. Moving nodes via insertBefore keeps
    // element identity (no recreation) and preserves anchor references.
    if (msg.order) {
      msg.order.forEach(function(childId) {
        var child = anchors.get(childId);
        if (!child) return;
        var frag = document.createDocumentFragment();
        var node = child.start;
        while (node && node !== child.end) {
          var next = node.nextSibling;
          frag.appendChild(node);
          node = next;
        }
        frag.appendChild(child.end);
        parent.insertBefore(frag, a.end);
      });
    }

    // Defer bindAll so Shiny finishes processing all messages in the
    // current flush before we ask it to discover new output bindings
    setTimeout(function() { Shiny.bindAll(parent); }, 0);
  });

  // --- Event payload construction ---

  // Radios only fire `change` on the newly-checked element in practice,
  // but gate defensively so a stray deselect-change can't write a stale
  // value through any `change` listener (auto-bind `checked` synthetic or
  // explicit `onChange`). Browsers don't fire deselect-change in modern
  // UAs, so this is invisible in practice but rules out one class of
  // stale-value bug.
  function shouldSkip(el, eventName) {
    return eventName === 'change' &&
           el.tagName === 'INPUT' && el.type === 'radio' &&
           !el.checked;
  }

  // Attach the irid event envelope to a payload object: stable element
  // id, a per-event nonce, and a per-element monotonic sequence number.
  // Shared between DOM events (from `buildPayload`) and widget events
  // (from `sendWidgetEvent`) so both paths produce identical wire shapes
  // and share the same sequence counter.
  function attachPayloadMeta(payload, id) {
    payload.id = id;
    payload.nonce = Math.random();
    if (!sequences[id]) sequences[id] = 0;
    payload.__irid_seq = ++sequences[id];
    return payload;
  }

  function buildPayload(e, el, id) {
    var payload = {};
    // Extract all primitive-valued properties from the event object
    for (var key in e) {
      try {
        var val = e[key];
        if (typeof val === 'string' || typeof val === 'number' || typeof val === 'boolean') {
          payload[key] = val;
        }
      } catch (err) {
        // Some event properties may throw on access; skip them
      }
    }
    // Element properties (override event props if same name)
    payload.value = el.value;
    if (typeof el.valueAsNumber === 'number') {
      payload.valueAsNumber = el.valueAsNumber;
    }
    if (typeof el.checked === 'boolean') {
      payload.checked = el.checked;
    }
    return attachPayloadMeta(payload, id);
  }

  // Push a payload through the managed-state pipeline for `inputId`. Silent
  // no-op if no R subscriber exists — widget JS can register events/props
  // unconditionally and only the ones with an R-side handler round-trip.
  function pushManaged(inputId, id, payload) {
    var s = managed[inputId];
    if (!s) return;
    var p = attachPayloadMeta(Object.assign({}, payload || {}), id);
    s.dispatch(p);
  }

  // `sendEvent(event, payload)` — a widget notification.
  function sendWidgetEvent(id, event, payload) {
    pushManaged('irid_ev_' + id + '_' + event, id, payload || {});
  }

  // `setProp(key, value)` — the client → server half of a two-way prop. The
  // value rides under the `value` field (uniform across props, since each
  // has its own `irid_prop_{id}_{key}` input), the symmetric partner of the
  // server → client `irid-attr target="widget"` → `update` hook.
  function setWidgetProp(id, key, value) {
    pushManaged('irid_prop_' + id + '_' + key, id, { value: value });
  }

  // --- Rate limiting (throttle / debounce with optional coalesce) ---
  // NOTE: Shiny dispatches shiny:idle as a jQuery event, NOT a native DOM
  // event. All listeners must use $(document).one(), not addEventListener.

  var managed = {};  // inputId -> state object
  var idleListenerActive = false;

  function sendPayload(inputId, payload) {
    Shiny.setInputValue(inputId, payload, { priority: 'event' });
    onEventSent();
  }

  function onShinyIdle() {
    idleListenerActive = false;
    var anySent = false;
    for (var inputId in managed) {
      var s = managed[inputId];
      if (s.serverBusy) {
        s.serverBusy = false;
        if (s.maybeSend) s.maybeSend();
        if (s.serverBusy) anySent = true;
      }
    }
    if (anySent) {
      $(document).one('shiny:idle', onShinyIdle);
      idleListenerActive = true;
    }
  }

  function ensureIdleListener() {
    if (!idleListenerActive) {
      $(document).one('shiny:idle', onShinyIdle);
      idleListenerActive = true;
    }
  }

  // Attach a DOM listener that dispatches the event payload through
  // the managed state. Only invoked for `source !== "widget"` —
  // widget events skip this and push through `sendWidgetEvent` (which
  // calls `s.dispatch` directly).
  function attachListener(el, msg, dispatch) {
    el.addEventListener(msg.event, function(e) {
      if (shouldSkip(el, msg.event)) return;
      if (msg.preventDefault) e.preventDefault();
      if (msg.stopPropagation) e.stopPropagation();
      dispatch(buildPayload(e, el, msg.id));
    }, { capture: !!msg.capture, passive: !!msg.passive });
  }

  // A config-only event (irid_wire with dom_opts but no handler): apply the
  // DOM listener flags client-side and never round-trip to the server.
  function attachClientOnlyListener(el, msg) {
    el.addEventListener(msg.event, function(e) {
      if (shouldSkip(el, msg.event)) return;
      if (msg.preventDefault) e.preventDefault();
      if (msg.stopPropagation) e.stopPropagation();
    }, { capture: !!msg.capture, passive: !!msg.passive });
  }

  function setupThrottle(el, msg) {
    var s = {
      payload: null,
      timerRunning: false, timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      leading: msg.leading,
      maybeSend: null,
      dispatch: null
    };

    s.maybeSend = function() {
      if (s.coalesce && s.serverBusy) return;
      if (!s.timerReady) return;
      if (s.payload === null) return;
      var p = s.payload;
      s.payload = null;
      s.timerReady = false;
      s.serverBusy = true;
      sendPayload(msg.inputId, p);
      s.timerRunning = true;
      setTimeout(function() {
        s.timerRunning = false;
        s.timerReady = true;
        s.maybeSend();
      }, msg.ms);
      if (s.coalesce) ensureIdleListener();
    };

    s.dispatch = function(payload) {
      s.payload = payload;
      if (s.timerRunning) return;
      if (s.leading && !(s.coalesce && s.serverBusy)) {
        // Fire immediately, start cooldown timer
        var p = s.payload;
        s.payload = null;
        s.serverBusy = true;
        sendPayload(msg.inputId, p);
        s.timerRunning = true;
        setTimeout(function() {
          s.timerRunning = false;
          s.timerReady = true;
          s.maybeSend();
        }, msg.ms);
        if (s.coalesce) ensureIdleListener();
      } else {
        // Start timer, send when it fires
        s.timerRunning = true;
        setTimeout(function() {
          s.timerRunning = false;
          s.timerReady = true;
          s.maybeSend();
        }, msg.ms);
      }
    };

    managed[msg.inputId] = s;
    if (msg.source !== 'widget') attachListener(el, msg, s.dispatch);
  }

  function setupDebounce(el, msg) {
    var s = {
      payload: null,
      timerId: null, timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      maybeSend: null,
      dispatch: null
    };

    s.maybeSend = function() {
      if (s.coalesce && s.serverBusy) return;
      if (!s.timerReady) return;
      if (s.payload === null) return;
      var p = s.payload;
      s.payload = null;
      s.timerReady = false;
      s.serverBusy = true;
      sendPayload(msg.inputId, p);
      if (s.coalesce) ensureIdleListener();
    };

    s.dispatch = function(payload) {
      s.payload = payload;
      s.timerReady = false;
      if (s.timerId !== null) clearTimeout(s.timerId);
      s.timerId = setTimeout(function() {
        s.timerId = null;
        s.timerReady = true;
        s.maybeSend();
      }, msg.ms);
    };

    managed[msg.inputId] = s;
    if (msg.source !== 'widget') attachListener(el, msg, s.dispatch);
  }

  function setupImmediate(el, msg) {
    // Two paths: a managed-state path (coalesce, or widget — widget
    // events always need managed state since they reach the pipeline
    // through `sendWidgetEvent` rather than a DOM listener), and a
    // direct-send path for plain DOM immediate-no-coalesce.
    if (msg.coalesce || msg.source === 'widget') {
      var s = {
        payload: null,
        serverBusy: false,
        coalesce: !!msg.coalesce,
        maybeSend: null,
        dispatch: null
      };

      s.maybeSend = function() {
        if (s.coalesce && s.serverBusy) return;
        if (s.payload === null) return;
        var p = s.payload;
        s.payload = null;
        if (s.coalesce) s.serverBusy = true;
        sendPayload(msg.inputId, p);
        if (s.coalesce) ensureIdleListener();
      };

      s.dispatch = function(payload) {
        s.payload = payload;
        s.maybeSend();
      };

      managed[msg.inputId] = s;
      if (msg.source !== 'widget') attachListener(el, msg, s.dispatch);
    } else {
      el.addEventListener(msg.event, function(e) {
        if (shouldSkip(el, msg.event)) return;
        if (msg.preventDefault) e.preventDefault();
        if (msg.stopPropagation) e.stopPropagation();
        sendPayload(msg.inputId, buildPayload(e, el, msg.id));
      }, { capture: !!msg.capture, passive: !!msg.passive });
    }
  }

  Shiny.addCustomMessageHandler('irid-events', function(msgs) {
    msgs.forEach(function(msg) {
      // Key on the (namespaced) inputId — unique per id/event/kind, so a
      // widget prop and a same-named event can't collide.
      var key = msg.inputId;
      if (eventsRegistered.has(key)) return;
      // DOM events need the element to exist for `addEventListener`.
      // Widget events bypass that step, so a missing element is fine
      // (and shouldn't happen since the container is in the DOM by
      // the time mount runs).
      var el = document.getElementById(msg.id);
      if (msg.source !== 'widget' && !el) return;
      eventsRegistered.add(key);
      if (msg.clientOnly) {
        // No server handler — just apply DOM flags, no managed state.
        attachClientOnlyListener(el, msg);
        return;
      }
      if (msg.mode === 'throttle') {
        setupThrottle(el, msg);
      } else if (msg.mode === 'debounce') {
        setupDebounce(el, msg);
      } else {
        setupImmediate(el, msg);
      }
    });
  });

  // --- Widget registry & lifecycle ---

  function mountWidget(id, name, props, factory) {
    if (widgets[id]) return;  // idempotent — duplicate init is a no-op
    var el = document.getElementById(id);
    if (!el) {
      // The init message is supposed to arrive after the swap/mutate
      // that introduces the container, so this is rare. Drop quietly
      // rather than throwing so a stray ordering bug doesn't crash
      // the session.
      console.warn('irid: widget container not found for id=' + id);
      return;
    }
    var sendEvent = function(event, payload) {
      sendWidgetEvent(id, event, payload);
    };
    var setProp = function(key, value) {
      setWidgetProp(id, key, value);
    };
    var handle = factory(el, props, sendEvent, setProp) || {};
    widgets[id] = { handle: handle, name: name };
  }

  // Destroy any widget instances inside `root` (an Element, fragment,
  // or detached subtree). Called from `detachRange` / `irid-swap`'s
  // inline detach BEFORE `Shiny.unbindAll` so widget `destroy()` runs
  // while the subtree is still attached / intact.
  function destroyWidgetsIn(root) {
    if (root.nodeType === 1 && root.hasAttribute('data-irid-widget')) {
      var w = widgets[root.id];
      if (w && w.handle && typeof w.handle.destroy === 'function') {
        try { w.handle.destroy(); } catch (e) { console.error(e); }
      }
      delete widgets[root.id];
    }
    if (typeof root.querySelectorAll === 'function') {
      var els = root.querySelectorAll('[data-irid-widget]');
      for (var i = 0; i < els.length; i++) {
        var w2 = widgets[els[i].id];
        if (w2 && w2.handle && typeof w2.handle.destroy === 'function') {
          try { w2.handle.destroy(); } catch (e) { console.error(e); }
        }
        delete widgets[els[i].id];
      }
    }
  }

  window.irid = {
    defineWidget: function(name, factory) {
      defined.set(name, factory);
      var queue = pendingInits[name];
      if (queue) {
        delete pendingInits[name];
        queue.forEach(function(init) {
          mountWidget(init.id, name, init.props, factory);
        });
      }
    }
  };

  Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
    if (widgets[msg.id]) return;  // idempotent
    // Shiny.renderDependencies returns undefined synchronously in
    // current Shiny versions; Promise.resolve normalizes both the
    // sync and the documented Promise-returning shapes so the .then
    // continuation runs once deps are loaded either way.
    Promise.resolve(Shiny.renderDependencies(msg.deps || [])).then(function() {
      var factory = defined.get(msg.name);
      if (!factory) {
        if (!pendingInits[msg.name]) pendingInits[msg.name] = [];
        pendingInits[msg.name].push({ id: msg.id, props: msg.props });
        return;
      }
      mountWidget(msg.id, msg.name, msg.props, factory);
    });
  });
})();

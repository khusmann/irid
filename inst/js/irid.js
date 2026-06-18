(function() {
  var eventsRegistered = new Set();  // `${id}:${event}` keys — once-per-pair listener install
  var sequences = {};  // channel (send inputId) -> latest sent sequence number
  var PROP_ATTRS = { value: true, disabled: true, checked: true, innerHTML: true };
  var anchors = new Map();  // id -> { start: CommentNode, end: CommentNode }
  var ANCHOR_RE = /^irid:(s|e):(.+)$/;
  var staleTimeout = null;  // ms before showing stale indicator (null = disabled)
  var staleShowTimerId = null;
  var staleClearTimerId = null;
  var STALE_CLEAR_DELAY = 100;  // ms to wait after idle before removing overlay

  // --- Widget registry ---
  // `defined` maps a widget registry name to its factory. Inits that arrive
  // before the factory is registered (factory-script load race) are buffered
  // under `pendingInits[name]` and drained in arrival order when
  // defineWidget(name, ...) lands. `widgets` is the live per-id table:
  // `{id -> {handle, name, pending, destroyed}}`.
  //
  // A factory may be SYNCHRONOUS (returns the handle) or ASYNCHRONOUS (returns
  // a Promise of the handle — e.g. `async function` that awaits a library
  // global, an ESM import, or a WASM init; see Widgets in ARCHITECTURE.md). The
  // entry is created synchronously at mount with `handle = null`; for an async
  // factory it stays that way until the promise resolves and `handle` is filled
  // in. `pending` buffers any `update` payloads that land during that window
  // (flushed once the handle commits); `destroyed` records a teardown that
  // happened mid-construction, so the resolved handle is disposed, not adopted.
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
  // Stale-echo gate. When the user produces events faster than the server can
  // echo them back, an echo for an earlier value can arrive after newer ones
  // have been sent. Each channel's counter (`sequences[channel]`) is bumped in
  // `attachPayloadMeta` on every outbound send, so it moves ahead of an
  // in-flight echo as soon as the user produces another event ON THE SAME
  // CHANNEL. Inert when no sequence/channel is present (programmatic updates),
  // or when the channel's counter hasn't moved past the echo's seq.
  function isStaleEcho(seq, channel) {
    return seq !== undefined && seq !== null &&
           channel !== undefined && channel !== null &&
           sequences[channel] !== undefined &&
           seq < sequences[channel];
  }

  Shiny.addCustomMessageHandler('irid-attr', function(msg) {
    if (msg.target === 'widget') {
      // Route to the widget's update hook. Skip if no widget is
      // registered for this id — covers the timing-dependent reorder
      // where an attr message arrives before the matching init
      // (defense in depth; mount sends init before any attr).
      var w = widgets[msg.id];
      if (!w) return;
      // `values` is always a `{attr -> value}` map (one or more keys),
      // coalesced server-side per widget per flush. A single-prop change is
      // just a one-entry map. The gate is PER KEY: a batch can carry props
      // from different channels (e.g. xaxis_range + yaxis_range from one box
      // zoom), so each key is gated against its own channel via `value_meta`
      // (`{key -> {seq, channel}}`). Keys with no `value_meta` entry are
      // programmatic and always apply.
      var values = msg.values;
      if (msg.value_meta) {
        var kept = {};
        var any = false;
        for (var k in values) {
          var meta = msg.value_meta[k];
          if (meta && isStaleEcho(meta.seq, meta.channel)) continue;
          kept[k] = values[k];
          any = true;
        }
        if (!any) return;  // every key gated out — nothing to apply
        values = kept;
      }
      if (w.handle) {
        if (typeof w.handle.update === 'function') w.handle.update(values);
      } else {
        // Async construction still in flight — buffer, coalescing by key
        // (later wins, same as the server-side per-flush batch). Flushed when
        // the handle commits in mountWidget.
        w.pending = Object.assign(w.pending || {}, values);
      }
      return;
    }

    // dom/text stale-echo gate (single channel per message).
    if (isStaleEcho(msg.sequence, msg.channel)) return;

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
  // id, a per-event nonce, and a per-CHANNEL monotonic sequence number.
  // `channel` is the inputId the payload is sent on (`session$ns(input_id)`),
  // so each client→server stream from an element — a DOM event, a widget
  // event, a widget prop write-back — owns its own counter. The inbound
  // stale-echo gate compares an echo against the counter of the channel that
  // produced it, so a sibling channel's send can't gate another channel's
  // echo (see the `irid-attr` handler). Shared between DOM events (from
  // `buildPayload`) and widget events (from `pushManaged`) so both paths
  // produce identical wire shapes.
  function attachPayloadMeta(payload, id, channel) {
    payload.id = id;
    payload.nonce = Math.random();
    if (!sequences[channel]) sequences[channel] = 0;
    payload.__irid_seq = ++sequences[channel];
    return payload;
  }

  function buildPayload(e, el, id, channel) {
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
    return attachPayloadMeta(payload, id, channel);
  }

  // Push a payload through a managed stream `s`. Silent no-op if `s` is
  // missing — widget JS can register events/props unconditionally and only
  // the ones with an R-side handler resolve to a stream. The channel/counter
  // key is `s.inputId` (the namespaced send target), so the per-channel
  // sequence stays correct under Shiny modules.
  function pushManaged(s, id, payload) {
    if (!s) return;
    var p = attachPayloadMeta(Object.assign({}, payload || {}), id, s.inputId);
    s.dispatch(p);
  }

  // `sendEvent(event, payload)` — a widget notification.
  function sendWidgetEvent(id, event, payload) {
    pushManaged(widgetStreams['event:' + id + ':' + event], id, payload || {});
  }

  // `setProp(key, value)` — the client → server half of a two-way prop. The
  // value rides under the `value` field (uniform across props, since each
  // has its own `irid_prop_{id}_{key}` input), the symmetric partner of the
  // server → client `irid-attr target="widget"` → `update` hook.
  function setWidgetProp(id, key, value) {
    pushManaged(widgetStreams['prop:' + id + ':' + key], id, { value: value });
  }

  // --- Rate limiting (throttle / debounce with optional coalesce) ---
  // NOTE: Shiny dispatches shiny:idle as a jQuery event, NOT a native DOM
  // event. All listeners must use $(document).one(), not addEventListener.

  var managed = {};  // inputId -> state object
  // Widget client→server streams indexed by the stable `{kind}:{id}:{event}`
  // triple a factory's `sendEvent`/`setProp` actually knows. `managed` is
  // keyed by the namespaced inputId, which a widget factory can't reconstruct
  // (it doesn't know the module namespace), so a separate index resolves the
  // stream — see `sendWidgetEvent`/`setWidgetProp`. Populated from `irid-events`
  // for `source === "widget"`.
  var widgetStreams = {};
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

  // --- Per-element ordered send queue --------------------------------------
  // Each (element,event) stream has its own rate-limit timer, so an immediate
  // event (onKeyDown) can overtake a still-debouncing one (the value binding's
  // onInput) and reach the server first — the todo "Enter before onInput
  // flushes" bug. A per-element FIFO of pending streams restores ordering: a
  // stream JOINS the moment it first buffers a payload (claim order) and a ready
  // stream drains in claim order, preemptively flushing an earlier stream still
  // waiting on its timer. Cutting a debounce short is correct — a later event on
  // the same element is exactly the signal the user paused. Ordering beats
  // backpressure: a preemptive flush sends even when the stream would otherwise
  // gate on serverBusy, while a stream's own steady-state sends still respect
  // coalesce. Relies on Shiny processing back-to-back event-priority inputs in
  // send order (verified against Shiny 1.7.4 — re-confirm on bump).
  var elementQueues = {};  // elementId -> [stream, ...] pending, claim order

  function queueJoin(s) {
    var q = elementQueues[s.id] || (elementQueues[s.id] = []);
    if (q.indexOf(s) === -1) q.push(s);
  }

  // Mark `s` ready to send `payload` (may be null), then drain its element.
  function queueReady(s, payload) {
    s.qPayload = payload;
    s.qReady = true;
    queueJoin(s);
    drainQueue(s.id);
  }

  function drainQueue(elId) {
    var q = elementQueues[elId];
    if (!q) return;
    while (q.length) {
      var head = q[0];
      if (!head.qReady) {
        var laterReady = false;
        for (var i = 1; i < q.length; i++) {
          if (q[i].qReady) { laterReady = true; break; }
        }
        if (!laterReady) break;   // head still legitimately waiting; stop
        head.qFlush();            // preempt: cancel timer, surface its buffer
      }
      q.shift();
      var p = head.qPayload;
      head.qPayload = null;
      head.qReady = false;
      // Null guard: a slot claimed with no payload is dropped, not sent empty.
      if (p !== null && p !== undefined) {
        sendPayload(head.inputId, p);
        if (head.coalesce) { head.serverBusy = true; ensureIdleListener(); }
      }
    }
  }

  // Compile a `wire_dom_opts(filter = ...)` expression into a predicate
  // over the DOM event `e`, or null when no filter is set. A filtered-out
  // event is dropped before any `preventDefault`/`stopPropagation` or
  // dispatch, so the page's default behavior is left untouched.
  function compileFilter(msg) {
    if (!msg.filter) return null;
    try {
      return new Function('e', 'return (' + msg.filter + ');');
    } catch (err) {
      console.error('irid: invalid event filter expression:', msg.filter, err);
      return null;
    }
  }

  // Attach a DOM listener that dispatches the event payload through
  // the managed state. Only invoked for `source !== "widget"` —
  // widget events skip this and push through `sendWidgetEvent` (which
  // calls `s.dispatch` directly).
  function attachListener(el, msg, dispatch) {
    var filter = compileFilter(msg);
    el.addEventListener(msg.event, function(e) {
      if (shouldSkip(el, msg.event)) return;
      if (filter && !filter(e)) return;
      if (msg.preventDefault) e.preventDefault();
      if (msg.stopPropagation) e.stopPropagation();
      dispatch(buildPayload(e, el, msg.id, msg.inputId));
    }, { capture: !!msg.capture, passive: !!msg.passive });
  }

  // A config-only event (wire with dom_opts but no handler): apply the
  // DOM listener flags client-side and never round-trip to the server.
  function attachClientOnlyListener(el, msg) {
    var filter = compileFilter(msg);
    el.addEventListener(msg.event, function(e) {
      if (shouldSkip(el, msg.event)) return;
      if (filter && !filter(e)) return;
      if (msg.preventDefault) e.preventDefault();
      if (msg.stopPropagation) e.stopPropagation();
    }, { capture: !!msg.capture, passive: !!msg.passive });
  }

  function setupThrottle(el, msg) {
    var s = {
      id: msg.id, inputId: msg.inputId,
      payload: null,
      timerRunning: false, timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      leading: msg.leading,
      qPayload: null, qReady: false,
      maybeSend: null, dispatch: null, qFlush: null
    };

    function startCooldown() {
      s.timerRunning = true;
      setTimeout(function() {
        s.timerRunning = false;
        s.timerReady = true;
        s.maybeSend();
      }, msg.ms);
    }

    s.maybeSend = function() {
      if (s.coalesce && s.serverBusy) return;
      if (!s.timerReady) return;
      if (s.payload === null) return;
      var p = s.payload;
      s.payload = null;
      s.timerReady = false;
      queueReady(s, p);
      startCooldown();
    };

    s.dispatch = function(payload) {
      s.payload = payload;
      queueJoin(s);              // claim slot at DOM-event time
      if (s.timerRunning) return;
      if (s.leading && !(s.coalesce && s.serverBusy)) {
        // Fire immediately, start cooldown timer
        var p = s.payload;
        s.payload = null;
        queueReady(s, p);
        startCooldown();
      } else {
        // Start timer, send when it fires
        startCooldown();
      }
    };

    // Preempt: the leading edge already fired; surface the trailing buffer.
    s.qFlush = function() {
      s.qPayload = s.payload;
      s.payload = null;
      s.timerReady = false;
      s.qReady = true;
    };

    managed[msg.inputId] = s;
    if (msg.source !== 'widget') attachListener(el, msg, s.dispatch);
  }

  function setupDebounce(el, msg) {
    var s = {
      id: msg.id, inputId: msg.inputId,
      payload: null,
      timerId: null, timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      qPayload: null, qReady: false,
      maybeSend: null, dispatch: null, qFlush: null
    };

    s.maybeSend = function() {
      if (s.coalesce && s.serverBusy) return;
      if (!s.timerReady) return;
      if (s.payload === null) return;
      var p = s.payload;
      s.payload = null;
      s.timerReady = false;
      queueReady(s, p);
    };

    s.dispatch = function(payload) {
      s.payload = payload;
      s.timerReady = false;
      queueJoin(s);              // claim slot at DOM-event time
      if (s.timerId !== null) clearTimeout(s.timerId);
      s.timerId = setTimeout(function() {
        s.timerId = null;
        s.timerReady = true;
        s.maybeSend();
      }, msg.ms);
    };

    // Preempt: a later sibling is ready and we're the head. Cancel the timer
    // and surface the buffered payload (null -> dropped by the drain).
    s.qFlush = function() {
      if (s.timerId !== null) { clearTimeout(s.timerId); s.timerId = null; }
      s.timerReady = false;
      s.qPayload = s.payload;
      s.payload = null;
      s.qReady = true;
    };

    managed[msg.inputId] = s;
    if (msg.source !== 'widget') attachListener(el, msg, s.dispatch);
  }

  function setupImmediate(el, msg) {
    // All immediate streams route through the element queue so a plain
    // immediate event (e.g. onKeyDown) can preemptively flush a sibling
    // debounced stream before sending. Widget events reach `dispatch` through
    // `sendWidgetEvent` rather than a DOM listener, so they skip attachListener.
    var s = {
      id: msg.id, inputId: msg.inputId,
      payload: null,
      serverBusy: false,
      coalesce: !!msg.coalesce,
      qPayload: null, qReady: false,
      maybeSend: null, dispatch: null, qFlush: null
    };

    s.maybeSend = function() {
      if (s.coalesce && s.serverBusy) return;
      if (s.payload === null) return;
      var p = s.payload;
      s.payload = null;
      queueReady(s, p);
    };

    s.dispatch = function(payload) {
      s.payload = payload;
      queueJoin(s);              // claim slot at DOM-event time
      s.maybeSend();
    };

    // Immediate streams are ready the instant they buffer, so a preempt only
    // happens in a race; surface whatever is buffered.
    s.qFlush = function() {
      s.qPayload = s.payload;
      s.payload = null;
      s.qReady = true;
    };

    managed[msg.inputId] = s;
    if (msg.source !== 'widget') attachListener(el, msg, s.dispatch);
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
      // Index widget streams by the `{kind}:{id}:{event}` triple a factory's
      // `sendEvent`/`setProp` resolves against (module-namespace-agnostic).
      if (msg.source === 'widget') {
        widgetStreams[msg.kind + ':' + msg.id + ':' + msg.event] =
          managed[msg.inputId];
      }
    });
  });

  // --- Widget registry & lifecycle ---

  function mountWidget(id, name, props, factory) {
    if (widgets[id]) return;  // idempotent — duplicate init (in-flight or live)
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
    // Reserve the id synchronously so a duplicate init is idempotent, an attr
    // arriving mid-construction buffers (see irid-attr), and a teardown
    // mid-construction is recorded.
    var entry = { handle: null, name: name, pending: null, destroyed: false };
    widgets[id] = entry;

    // Adopt the resolved handle — unless the widget was torn down (or its id
    // re-mounted) while an async factory was still constructing, in which case
    // dispose the just-built handle instead of registering a zombie.
    function commit(handle) {
      handle = handle || {};
      if (entry.destroyed || widgets[id] !== entry) {
        if (typeof handle.destroy === 'function') {
          try { handle.destroy(); } catch (e) { console.error(e); }
        }
        return;
      }
      entry.handle = handle;
      if (entry.pending) {
        if (typeof handle.update === 'function') handle.update(entry.pending);
        entry.pending = null;
      }
    }

    // A factory may return the handle directly (sync) or a Promise of it
    // (async — e.g. `async function` awaiting a library global / import / WASM
    // init). Sync factories commit synchronously, preserving today's timing.
    var result;
    try {
      result = factory(el, props, sendEvent, setProp);
    } catch (e) {
      console.error('irid: widget factory threw for ' + name, e);
      if (widgets[id] === entry) delete widgets[id];
      return;
    }
    if (result && typeof result.then === 'function') {
      result.then(commit, function(err) {
        console.error('irid: widget factory failed for ' + name, err);
        if (widgets[id] === entry) delete widgets[id];
      });
    } else {
      commit(result);
    }
  }

  // Tear down one widget id: run its destroy hook if the handle has committed,
  // and flag the entry so an async factory still in flight disposes the handle
  // it's about to produce (see commit() in mountWidget) instead of leaving a
  // detached zombie.
  function destroyWidget(id) {
    var w = widgets[id];
    if (!w) return;
    w.destroyed = true;
    if (w.handle && typeof w.handle.destroy === 'function') {
      try { w.handle.destroy(); } catch (e) { console.error(e); }
    }
    delete widgets[id];
  }

  // Destroy any widget instances inside `root` (an Element, fragment,
  // or detached subtree). Called from `detachRange` / `irid-swap`'s
  // inline detach BEFORE `Shiny.unbindAll` so widget `destroy()` runs
  // while the subtree is still attached / intact.
  function destroyWidgetsIn(root) {
    if (root.nodeType === 1 && root.hasAttribute('data-irid-widget')) {
      destroyWidget(root.id);
    }
    if (typeof root.querySelectorAll === 'function') {
      var els = root.querySelectorAll('[data-irid-widget]');
      for (var i = 0; i < els.length; i++) destroyWidget(els[i].id);
    }
  }

  window.irid = {
    // defineWidget(name, factory) — `factory(el, props, sendEvent, setProp)`
    // returns the `{update, destroy}` handle, OR a Promise of it. Make the
    // factory `async` and `await` whatever its construction needs first — a
    // library global delivered by a Shiny dependency (poll for it; see the
    // PlotlyOutput factory's `whenPlotly`), an ESM `import(...)`, a WASM init.
    // irid awaits the return before delivering updates, buffering any that
    // arrive meanwhile and disposing cleanly if the widget is torn down
    // mid-construction. A widget whose deps are already present (e.g. an ESM
    // widget) just returns the handle synchronously.
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

  // The init message carries no deps — a widget's dep `<script>`/`<link>`
  // assets are delivered via insertUI at mount time (Shiny's native render
  // pipeline; see the R-side `deliver_widget_deps`). The factory script
  // therefore always loads after irid.js, so `window.irid` exists when it calls
  // `defineWidget`. An init that still beats its factory (the insert delivers it
  // a moment later) parks under `pendingInits` and drains on `defineWidget`.
  Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
    if (widgets[msg.id]) return;  // idempotent
    var factory = defined.get(msg.name);
    if (!factory) {
      if (!pendingInits[msg.name]) pendingInits[msg.name] = [];
      pendingInits[msg.name].push({ id: msg.id, props: msg.props });
      return;
    }
    mountWidget(msg.id, msg.name, msg.props, factory);
  });
})();

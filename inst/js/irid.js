(function() {
  var defined = new Set();
  var sequences = {};  // element id -> latest sent sequence number
  var PROP_ATTRS = { value: true, disabled: true, checked: true, selected: true, innerHTML: true };
  var anchors = new Map();  // id -> { start: CommentNode, end: CommentNode }
  var ANCHOR_RE = /^irid:(s|e):(.+)$/;
  var staleTimeout = null;  // ms before showing stale indicator (null = disabled)
  var staleShowTimerId = null;
  var staleClearTimerId = null;
  var STALE_CLEAR_DELAY = 100;  // ms to wait after idle before removing overlay

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
      if (n.nodeType === 1) Shiny.unbindAll(n);
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

  Shiny.addCustomMessageHandler('irid-attr', function(msg) {
    var el = document.getElementById(msg.id);
    if (!el) return;
    if (msg.attr === 'value' && document.activeElement === el) {
      if (msg.sequence !== undefined && msg.sequence !== null) {
        if (sequences[msg.id] !== undefined && msg.sequence < sequences[msg.id]) {
          return; // Stale echo from earlier event, skip
        }
      }
      // Programmatic (no sequence) or up-to-date: apply, but skip no-op
      if (el.value === msg.value) return;
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
      if (n.nodeType === 1) Shiny.unbindAll(n);
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
    payload.id = id;
    payload.nonce = Math.random();
    if (!sequences[id]) sequences[id] = 0;
    payload.__irid_seq = ++sequences[id];
    return payload;
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

  function setupThrottle(el, msg) {
    var s = {
      payload: null,
      timerRunning: false, timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      leading: msg.leading,
      maybeSend: null
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

    managed[msg.inputId] = s;

    el.addEventListener(msg.event, function(e) {
      if (msg.preventDefault) e.preventDefault();
      s.payload = buildPayload(e, el, msg.id);
      if (!s.timerRunning) {
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
      }
    });
  }

  function setupDebounce(el, msg) {
    var s = {
      payload: null,
      timerId: null, timerReady: false,
      serverBusy: false,
      coalesce: msg.coalesce,
      maybeSend: null
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

    managed[msg.inputId] = s;

    el.addEventListener(msg.event, function(e) {
      if (msg.preventDefault) e.preventDefault();
      s.payload = buildPayload(e, el, msg.id);
      s.timerReady = false;
      if (s.timerId !== null) clearTimeout(s.timerId);
      s.timerId = setTimeout(function() {
        s.timerId = null;
        s.timerReady = true;
        s.maybeSend();
      }, msg.ms);
    });
  }

  function setupImmediate(el, msg) {
    if (msg.coalesce) {
      var s = {
        payload: null,
        serverBusy: false,
        coalesce: true,
        maybeSend: null
      };

      s.maybeSend = function() {
        if (s.serverBusy) return;
        if (s.payload === null) return;
        var p = s.payload;
        s.payload = null;
        s.serverBusy = true;
        sendPayload(msg.inputId, p);
        ensureIdleListener();
      };

      managed[msg.inputId] = s;

      el.addEventListener(msg.event, function(e) {
        if (msg.preventDefault) e.preventDefault();
        s.payload = buildPayload(e, el, msg.id);
        s.maybeSend();
      });
    } else {
      el.addEventListener(msg.event, function(e) {
        if (msg.preventDefault) e.preventDefault();
        sendPayload(msg.inputId, buildPayload(e, el, msg.id));
      });
    }
  }

  Shiny.addCustomMessageHandler('irid-events', function(msgs) {
    msgs.forEach(function(msg) {
      var el = document.getElementById(msg.id);
      if (!el) return;
      var key = msg.id + ':' + msg.event;
      if (defined.has(key)) return;
      defined.add(key);
      if (msg.mode === 'throttle') {
        setupThrottle(el, msg);
      } else if (msg.mode === 'debounce') {
        setupDebounce(el, msg);
      } else {
        setupImmediate(el, msg);
      }
    });
  });
})();

(function() {
  var defined = new Set();
  var sequences = {};  // element id -> latest sent sequence number
  var PROP_ATTRS = { value: true, disabled: true, checked: true, selected: true };
  var staleTimeout = null;  // ms before showing stale indicator (null = disabled)
  var staleShowTimerId = null;
  var staleClearTimerId = null;
  var STALE_CLEAR_DELAY = 100;  // ms to wait after idle before removing overlay

  function markStale() {
    if (staleClearTimerId !== null) {
      clearTimeout(staleClearTimerId);
      staleClearTimerId = null;
    }
    document.documentElement.classList.add('nacre-stale');
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
        document.documentElement.classList.remove('nacre-stale');
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
        !document.documentElement.classList.contains('nacre-stale')) {
      staleShowTimerId = setTimeout(markStale, staleTimeout);
    }
  }

  // Clear stale state when server finishes processing
  $(document).on('shiny:idle', function() {
    clearStale();
  });

  Shiny.addCustomMessageHandler('nacre-config', function(msg) {
    if (msg.staleTimeout !== undefined && msg.staleTimeout !== null) {
      staleTimeout = msg.staleTimeout;
    } else {
      staleTimeout = null;
    }
  });

  Shiny.addCustomMessageHandler('nacre-attr', function(msg) {
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

  Shiny.addCustomMessageHandler('nacre-swap', function(msg) {
    var el = document.getElementById(msg.id);
    if (!el) return;
    Shiny.unbindAll(el);
    el.innerHTML = msg.html;
    // Defer bindAll so Shiny finishes processing all messages in the
    // current flush before we ask it to discover new output bindings
    setTimeout(function() { Shiny.bindAll(el); }, 0);
  });

  Shiny.addCustomMessageHandler('nacre-mutate', function(msg) {
    var el = document.getElementById(msg.id);
    if (!el) return;

    // 1. Remove children
    if (msg.removes) {
      msg.removes.forEach(function(childId) {
        var child = document.getElementById(childId);
        if (child) {
          Shiny.unbindAll(child);
          child.remove();
        }
      });
    }

    // 2. Insert new children (append to end)
    if (msg.inserts) {
      msg.inserts.forEach(function(html) {
        var temp = document.createElement('div');
        temp.innerHTML = html;
        while (temp.firstChild) {
          el.appendChild(temp.firstChild);
        }
      });
    }

    // 3. Reorder children to match desired order (optional)
    if (msg.order) {
      msg.order.forEach(function(childId) {
        var child = document.getElementById(childId);
        if (child) el.appendChild(child);
      });
    }

    // Defer bindAll so Shiny finishes processing all messages in the
    // current flush before we ask it to discover new output bindings
    setTimeout(function() { Shiny.bindAll(el); }, 0);
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
    payload.__nacre_seq = ++sequences[id];
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

  Shiny.addCustomMessageHandler('nacre-events', function(msgs) {
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

(function() {
  var defined = new Set();
  var PROP_ATTRS = { value: true, disabled: true, checked: true, selected: true };

  Shiny.addCustomMessageHandler('nacre-attr', function(msg) {
    var el = document.getElementById(msg.id);
    if (!el) return;
    if (document.activeElement === el && msg.attr === 'value') return;
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
    return payload;
  }

  // --- Rate limiting (throttle / debounce with optional coalesce) ---
  // NOTE: Shiny dispatches shiny:idle as a jQuery event, NOT a native DOM
  // event. All listeners must use $(document).one(), not addEventListener.

  var managed = {};  // inputId -> state object
  var idleListenerActive = false;

  function sendPayload(inputId, payload) {
    Shiny.setInputValue(inputId, payload, { priority: 'event' });
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

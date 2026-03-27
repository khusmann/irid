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

  Shiny.addCustomMessageHandler('nacre-events', function(msgs) {
    msgs.forEach(function(msg) {
      var el = document.getElementById(msg.id);
      if (!el) return;
      var key = msg.id + ':' + msg.event;
      if (defined.has(key)) return;
      defined.add(key);
      el.addEventListener(msg.event, function(e) {
        Shiny.setInputValue(msg.inputId, {
          value: el.value,
          id: msg.id,
          nonce: Math.random()
        }, { priority: 'event' });
      });
    });
  });
})();

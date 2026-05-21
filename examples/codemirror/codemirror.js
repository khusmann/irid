// CodeMirror Widget — irid widget JS binding
//
// Registers with irid.registerWidget() so irid.js dispatches init
// messages to this init function. Uses irid.sendEvent() to forward
// CodeMirror change/cursorActivity events back to the R handler.

(function() {
  irid.registerWidget('codemirror', function(msg) {
    var el = document.getElementById(msg.id);
    if (!el) return;

    // ---- Poll for CodeMirror availability ----
    // The CodeMirror CDN script loads asynchronously. We must wait for it
    // before initializing, otherwise CodeMirror(el, {...}) throws a silent
    // ReferenceError and the editor never becomes interactive.
    function tryInit() {
      if (typeof CodeMirror === 'undefined') {
        setTimeout(tryInit, 50);
        return;
      }

      // --- Initialization ---
      var editor = CodeMirror(el, {
        value: msg.channels.content || '',
        mode: msg.channels.mode || msg.config.mode || 'javascript',
        lineNumbers: true,
        theme: msg.config.theme || 'default',
        viewportMargin: Infinity
      });

      // --- Track last-sent content to distinguish echoes from
      //     server-initiated updates ---
      var lastSentContent = null;

      // --- Forward editor events to R via irid.sendEvent ---
      editor.on('change', function(cm) {
        lastSentContent = cm.getValue();
        irid.sendEvent(msg.id, 'change', { value: lastSentContent });
      });

      editor.on('cursorActivity', function(cm) {
        var pos = cm.getCursor();
        irid.sendEvent(msg.id, 'cursorActivity', {
          line: pos.line,
          ch: pos.ch
        });
      });

      // --- React to server-pushed channel updates ---
      el.addEventListener('irid-widget-channel', function(e) {
        var detail = e.detail;
        if (detail.channel === 'content' && detail.value !== undefined) {
          // While the user is actively editing, don't overwrite the
          // editor — this prevents cursor jump and character loss when
          // a late channel echo arrives from a previous keystroke.
          if (editor.hasFocus()) {
            lastSentContent = null;
            return;
          }
          // If the incoming value matches what we last sent, it is an
          // echo back from the server — no need to write it back.
          if (lastSentContent !== null && detail.value === lastSentContent) {
            lastSentContent = null;
            return;
          }
          lastSentContent = null;
          // Server-initiated update (e.g. loading a different file).
          if (editor.getValue() !== detail.value) {
            editor.setValue(detail.value);
          }
        }
        if (detail.channel === 'mode' && detail.value) {
          editor.setOption('mode', detail.value);
        }
      });

      // --- Cleanup on widget destroy (e.g. When branch deactivates) ---
      el.addEventListener('irid-widget-destroy', function() {
        var wrapper = el.querySelector('.CodeMirror');
        if (wrapper) wrapper.remove();
        editor = null;
      });
    }

    tryInit();
  });
})();

# widget-async.R — e2e for irid's widget-factory contract (#26), independent of
# any real library. Two synthetic widgets exercise both factory paths:
#
#   testw  (ASYNC) — its factory blocks on a global `window.__testGo` the test
#     flips, making the construction window deterministic (real libs like Plotly
#     load too fast to observe it). Records lifecycle on `window.__tw` to assert:
#       - updates that arrive while the factory is still awaiting are BUFFERED
#         and delivered once it commits (not dropped);
#       - a teardown during construction DISPOSES the resolved handle (destroy
#         runs) rather than adopting a detached zombie.
#
#   testws (SYNC) — returns its handle directly (the `commit(result)` branch),
#     the CodeMirror-style "deps in scope at registration" path. Records on
#     `window.__tws` to assert it commits with no async window and delivers
#     updates normally.
#
# Both factories are registered from a <head> script (deps = NULL); it polls for
# `window.irid` so it's robust to head/dep load order, and irid's pendingInits
# buffers the init until defineWidget lands.

library(irid)

factory_js <- "
(function reg() {
  if (!(window.irid && window.irid.defineWidget)) { setTimeout(reg, 10); return; }

  // ASYNC factory: blocks on window.__testGo (deterministic construction window)
  window.__tw = { started: false, inited: false, updates: [],
                  destroyed: false, initialLabel: null };
  window.irid.defineWidget('testw', async function (el, props, sendEvent, setProp) {
    window.__tw.started = true;
    await new Promise(function (res) {
      var t = setInterval(function () {
        if (window.__testGo) { clearInterval(t); res(); }
      }, 20);
    });
    window.__tw.inited = true;
    window.__tw.initialLabel = props.label;
    el.textContent = props.label;
    return {
      update: function (values) {
        window.__tw.updates.push(values);
        if ('label' in values) el.textContent = values.label;
      },
      destroy: function () { window.__tw.destroyed = true; }
    };
  });

  // SYNC factory: returns the handle directly (the commit(result) branch).
  window.__tws = { inited: false, updates: [], destroyed: false,
                   initialLabel: null };
  window.irid.defineWidget('testws', function (el, props, sendEvent, setProp) {
    window.__tws.inited = true;
    window.__tws.initialLabel = props.label;
    el.textContent = props.label;
    return {
      update: function (values) {
        window.__tws.updates.push(values);
        if ('label' in values) el.textContent = values.label;
      },
      destroy: function () { window.__tws.destroyed = true; }
    };
  });
})();
"

App <- function() {
  label <- reactiveVal("A")
  show  <- reactiveVal(TRUE)

  tags$div(
    tags$head(tags$script(HTML(factory_js))),
    tags$button(id = "btn-change", onClick = \() label("B"), "change"),
    tags$button(id = "btn-hide", onClick = \() show(FALSE), "hide"),
    IridWidget("testws", props = list(label = label)),  # sync, always shown
    When(
      show,
      \() IridWidget("testw", props = list(label = label)),
      \() tags$div(id = "tw-hidden", "hidden")
    )
  )
}

App

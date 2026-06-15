# widget-async.R — e2e for irid's async-factory contract (#26), independent of
# any real library. A synthetic "testw" widget whose factory blocks on a global
# `window.__testGo` that the test flips, so the construction window is
# deterministic (real libs like Plotly load too fast to observe it).
#
# The factory records its lifecycle on `window.__tw` so the test can assert:
#   - updates that arrive while the factory is still awaiting are BUFFERED and
#     delivered once it commits (not dropped);
#   - a teardown during construction DISPOSES the resolved handle (destroy runs)
#     rather than adopting a detached zombie.
#
# The factory is registered from a <head> script (deps = NULL); it polls for
# `window.irid` so it's robust to head/dep load order, and irid's pendingInits
# buffers the init until defineWidget lands.

library(irid)

factory_js <- "
(function reg() {
  if (!(window.irid && window.irid.defineWidget)) { setTimeout(reg, 10); return; }
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
})();
"

App <- function() {
  label <- reactiveVal("A")
  show  <- reactiveVal(TRUE)

  tags$div(
    tags$head(tags$script(HTML(factory_js))),
    tags$button(id = "btn-change", onClick = \() label("B"), "change"),
    tags$button(id = "btn-hide", onClick = \() show(FALSE), "hide"),
    When(
      show,
      \() IridWidget("testw", props = list(label = label)),
      \() tags$div(id = "tw-hidden", "hidden")
    )
  )
}

App

// Delivered via sendCustomMessage -> Shiny.renderDependencies (the side channel
// from issue #34). Executes only if shinylive served this file-backed
// dependency mid-session — expected to 404 and never run (the control).
window.__SPIKE_MSG = true;
(function () {
  var el = document.getElementById("statusB");
  if (el) {
    el.textContent = "B) custom message (side channel, control): LOADED ✓";
    el.style.color = "#0a0";
  }
})();

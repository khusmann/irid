// Delivered via renderUI (Shiny's native render pipeline). Executes only if
// shinylive served this file-backed dependency mid-session.
window.__SPIKE_RENDERUI = true;
(function () {
  var el = document.getElementById("statusA");
  if (el) {
    el.textContent = "A) renderUI (native pipeline): LOADED ✓";
    el.style.color = "#0a0";
  }
})();

/* SketchDL live progress. ~2.8 KB, no dependencies.
   The page is fully usable without this file (3 s meta refresh fallback). */
(function () {
  "use strict";
  var box = document.getElementById("job-progress");
  if (!box || !window.EventSource) return;
  var job = box.getAttribute("data-job");
  if (!job) return;

  // Live updates replace the fallback refresh.
  var meta = document.querySelector('meta[http-equiv="refresh"]');
  if (meta) meta.parentNode.removeChild(meta);

  var bar = document.getElementById("bar");
  var bytes = document.getElementById("bytes");
  var speed = document.getElementById("speed");
  var eta = document.getElementById("eta");
  var stage = document.getElementById("stage");
  var state = document.getElementById("state");

  var labels = {
    "QUEUED": "queued",
    "DOWNLOADING": "downloading",
    "VERIFYING": "checking",
    "READY": "ready",
    "FAILED": "failed",
    "CANCELLED": "cancelled",
    "EXPIRED": "expired"
  };
  var stages = {
    "queued": "Waiting its turn",
    "downloading": "Downloading",
    "downloading-video": "Downloading video",
    "downloading-audio": "Downloading audio",
    "merging": "Merging audio and video",
    "verifying": "Checking the file"
  };

  function setText(el, text) {
    if (el && text !== undefined && text !== null) el.textContent = text;
  }

  function ensureBar() {
    if (bar && bar.parentNode) return bar;
    bar = document.createElement("progress");
    bar.id = "bar";
    bar.max = 100;
    bar.value = 0;
    bar.setAttribute("aria-label", "Download progress");
    box.insertBefore(bar, box.firstChild);
    return bar;
  }

  var es = new EventSource("/jobs/" + encodeURIComponent(job) + "/events");
  es.onmessage = function (ev) {
    var d;
    try { d = JSON.parse(ev.data); } catch (e) { return; }
    if (state && d.state) {
      state.textContent = labels[d.state] || d.state.toLowerCase();
      state.className = "state " + (labels[d.state] || "queued");
    }
    if (d.state === "READY" || d.state === "FAILED" || d.state === "CANCELLED" || d.state === "EXPIRED") {
      es.close();
      window.location.reload();
      return;
    }
    if (d.pct >= 0) {
      var p = ensureBar();
      p.value = d.pct;
      p.textContent = d.pct + "% complete";
      setText(bytes, d.bytes + " of " + d.total_text);
    } else if (bytes) {
      bytes.textContent = d.bytes + " so far";
    }
    setText(speed, d.speed_text);
    setText(eta, d.eta_text);
    if (stage) stage.textContent = stages[d.stage] || "Downloading";
  };
  es.onerror = function () {
    es.close();
    // If the stream dies, restore the no-JS fallback.
    if (!document.querySelector('meta[http-equiv="refresh"]')) {
      var m = document.createElement("meta");
      m.httpEquiv = "refresh";
      m.content = "3";
      document.head.appendChild(m);
    }
  };
})();

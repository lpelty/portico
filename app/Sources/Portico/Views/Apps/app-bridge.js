// Portico's MCP Apps bridge shim (v0.18 ruling 33). Portico-written, not third-party.
// The page is a top-level web view, so window.parent === window: what the page
// posts to its parent goes to the native host, and what the host says arrives
// as a "message" event from window. The JSON-RPC itself is the app's (Swift).
(function () {
  "use strict";
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mcpapp;
  if (!handler) return;
  var toHost = function (message) {
    var text;
    try { text = JSON.stringify(message); } catch (e) { text = "null"; }
    handler.postMessage(text === undefined ? "null" : text);
  };
  Object.defineProperty(window, "postMessage", {
    value: function (message) { toHost(message); },
    writable: false, configurable: false
  });
  Object.defineProperty(window, "__porticoDeliver", {
    value: function (text) {
      var data;
      try { data = JSON.parse(text); } catch (e) { return; }
      window.dispatchEvent(new MessageEvent("message", { data: data, source: window, origin: window.location.origin }));
    },
    writable: false, configurable: false
  });
})();

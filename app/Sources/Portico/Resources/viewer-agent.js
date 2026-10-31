// The viewer's agent script (v0.12, spec §3.2). The app installs it in
// every page the viewer shows, at document start, so page errors are
// captured from load; `ViewerAgent` (ViewerAgent.swift) calls it to build
// the outline a look returns and to click, type and scroll the way the
// page's own scripts would (synthetic DOM events). Refs are written to the
// elements as `data-portico-ref="eN"`; a ref is good for the page that
// numbered it (`page`), so one from another page is never followed.
(function () {
  "use strict";
  // `MARKER` tells this script's object from a page's own under the name;
  // keep it equal to `ViewerAgentScript.marker` (ViewerAgent.swift).
  var MARKER = "viewer-agent-1";
  var existing = window.__porticoAgent;
  if (existing && existing.__portico === MARKER) return;

  var MAX_ERRORS = 20;
  var ERROR_CHARS = 200;
  var MAX_LINES = 300;
  var NAME_CHARS = 80;
  var REF = "data-portico-ref";

  // MARK: page errors

  // Kept apart from `window.__porticoAgent`, so the script installed again
  // (a page replaced that object) keeps what was caught and listens once.
  var STORE = typeof Symbol === "function" ? Symbol.for("portico.viewer-agent.errors") : "__porticoErrors";
  var store = window[STORE];
  var listening = !!store;
  if (!store) {
    store = { errors: [] };
    Object.defineProperty(window, STORE, { value: store });
  }

  function note(text) {
    text = String(text);
    if (text.length > ERROR_CHARS) text = text.slice(0, ERROR_CHARS);
    store.errors.push(text);
    if (store.errors.length > MAX_ERRORS) store.errors.shift();
  }

  function describe(value) {
    if (value instanceof Error) return value.message ? value.name + ": " + value.message : String(value);
    if (typeof value === "string") return value;
    try {
      var json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    } catch (e) {
      return String(value);
    }
  }

  // Bubble phase only: a resource that fails to load fires `error` on its
  // element, which does not bubble, so only script errors reach here.
  if (!listening) {
    window.addEventListener("error", function (event) {
      note(event.message || describe(event.error));
    });
    window.addEventListener("unhandledrejection", function (event) {
      note("Unhandled rejection: " + describe(event.reason));
    });
    var consoleError = console.error;
    console.error = function () {
      note(Array.prototype.map.call(arguments, describe).join(" "));
      return consoleError.apply(console, arguments);
    };
  }

  // MARK: reading the page

  function squash(text) {
    return String(text || "").replace(/\s+/g, " ").trim();
  }

  function cut(text) {
    text = squash(text);
    return text.length > NAME_CHARS ? text.slice(0, NAME_CHARS - 1) + "…" : text;
  }

  function visible(el) {
    if (!el.getClientRects().length) return false;
    var style = getComputedStyle(el);
    return style.visibility !== "hidden";
  }

  function labelledBy(el) {
    var ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
    return ids.map(function (id) {
      var other = document.getElementById(id);
      return other ? other.innerText || other.textContent : "";
    }).join(" ");
  }

  var TEXT_INPUTS = ["", "text", "search", "email", "url", "tel", "number", "password",
    "date", "time", "datetime-local", "month", "week"];

  function inputType(el) {
    return (el.getAttribute("type") || "").toLowerCase();
  }

  function isField(el) {
    if (el.isContentEditable && el.getAttribute("contenteditable") !== null) return true;
    if (el.tagName === "TEXTAREA" || el.tagName === "SELECT") return true;
    return el.tagName === "INPUT" && TEXT_INPUTS.indexOf(inputType(el)) >= 0;
  }

  function name(el) {
    var aria = squash(el.getAttribute("aria-label")) || squash(labelledBy(el));
    if (aria) return aria;
    if (el.labels && el.labels.length) {
      var label = squash(Array.prototype.map.call(el.labels, function (l) { return l.innerText || l.textContent; }).join(" "));
      if (label) return label;
    }
    if (el.tagName === "IMG") return squash(el.getAttribute("alt"));
    if (el.tagName === "INPUT") {
      var type = inputType(el);
      if (type === "submit" || type === "button" || type === "reset") return squash(el.value) || type;
      return squash(el.getAttribute("placeholder")) || squash(el.getAttribute("title")) || squash(el.getAttribute("name"));
    }
    if (el.tagName === "TEXTAREA" || el.tagName === "SELECT") {
      return squash(el.getAttribute("placeholder")) || squash(el.getAttribute("title")) || squash(el.getAttribute("name"));
    }
    var text = squash(el.innerText || el.textContent);
    if (!text) {
      var img = el.querySelector("img[alt]");
      if (img) text = squash(img.getAttribute("alt"));
    }
    return text || squash(el.getAttribute("title"));
  }

  /// "<role>: <name>" and what it holds, or null when it is not listed.
  function describeElement(el) {
    var tag = el.tagName;
    var role = (el.getAttribute("role") || "").toLowerCase();
    if (/^H[1-6]$/.test(tag)) return "heading " + tag[1] + ": " + cut(el.innerText || el.textContent);
    if (tag === "DETAILS" && el.classList.contains("fm")) {
      var rows = Array.prototype.map.call(el.querySelectorAll(".fm-row"), function (row) {
        var key = squash((row.querySelector(".fm-key") || {}).textContent);
        var value = row.querySelector(".fm-value");
        var tags = value ? value.querySelectorAll(".fm-tag") : [];
        var shown = tags.length
          ? Array.prototype.map.call(tags, function (t) { return squash(t.textContent); }).join(", ")
          : squash(value ? value.textContent : "");
        return key + ": " + shown;
      });
      return "properties: " + rows.join(" · ");
    }
    if (tag === "SUMMARY") return "disclosure: " + cut(el.innerText || el.textContent);
    if ((tag === "A" && el.hasAttribute("href")) || role === "link") {
      var href = el.getAttribute("href");
      return "link: " + cut(name(el)) + (href ? " → " + href : "");
    }
    if (tag === "BUTTON" || role === "button") return "button: " + cut(name(el));
    if (tag === "INPUT") {
      var type = inputType(el);
      if (type === "hidden") return null;
      if (type === "submit" || type === "button" || type === "reset" || type === "image") return "button: " + cut(name(el));
      if (type === "checkbox") return "checkbox: " + cut(name(el)) + (el.checked ? " (checked)" : "");
      if (type === "radio") return "radio button: " + cut(name(el)) + (el.checked ? " (selected)" : "");
      if (type === "password") return "password field: " + cut(name(el));
      if (type === "range") return "slider: " + cut(name(el)) + " = " + el.value;
      var word = type === "" || type === "text" ? "text" : type;
      return word + " field: " + cut(name(el)) + (el.value ? ' = "' + cut(el.value) + '"' : "");
    }
    if (tag === "TEXTAREA") return "text area: " + cut(name(el)) + (el.value ? ' = "' + cut(el.value) + '"' : "");
    if (tag === "SELECT") {
      var picked = el.selectedOptions && el.selectedOptions[0];
      return "select: " + cut(name(el)) + (picked ? ' = "' + cut(picked.textContent) + '"' : "");
    }
    if (el.isContentEditable && el.getAttribute("contenteditable") !== null) return "editable text: " + cut(name(el));
    if (tag === "TABLE") {
      var caption = el.caption ? cut(el.caption.textContent) + ", " : "";
      var first = el.rows.length ? el.rows[0] : null;
      var columns = first ? Array.prototype.slice.call(first.cells, 0, 8).map(function (c) { return cut(c.textContent); }) : [];
      return "table: " + caption + el.rows.length + " rows" + (columns.length ? "; columns " + columns.join(", ") : "");
    }
    if (tag === "IMG") {
      var alt = squash(el.getAttribute("alt"));
      return alt ? "image: " + cut(alt) : null;
    }
    return null;
  }

  var LISTED = "h1,h2,h3,h4,h5,h6,a[href],[role=link],button,[role=button],input,select,textarea," +
    "[contenteditable],table,img[alt],details.fm,summary";

  function listed() {
    var out = [];
    var all = document.querySelectorAll(LISTED);
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      // The Properties block is one line; nothing inside it is listed apart.
      if (el.closest("details.fm") && !(el.tagName === "DETAILS" && el.classList.contains("fm"))) continue;
      if (el.matches("[contenteditable]") && !el.isContentEditable) continue;
      if (!visible(el)) continue;
      var line = describeElement(el);
      if (line) out.push({ el: el, line: line });
    }
    return out;
  }

  // MARK: refs

  var agent = { __portico: MARKER, page: Math.random().toString(36).slice(2), next: 0 };
  // Installed again on the same page: carry on numbering from the refs
  // already written, so a new ref never repeats an old one.
  Array.prototype.forEach.call(document.querySelectorAll("[data-portico-ref]"), function (el) {
    var n = parseInt(String(el.getAttribute("data-portico-ref")).slice(1), 10);
    if (n > agent.next) agent.next = n;
  });

  /// The element a ref names on its page, or the element whose name the
  /// text is (exactly, then partly), or null.
  function resolve(target, page, wantField) {
    target = squash(target);
    if (!target) return null;
    if (/^e\d+$/.test(target)) {
      if (page && page !== agent.page) return null;
      return document.querySelector("[" + REF + '="' + target + '"]');
    }
    var want = target.toLowerCase();
    var candidates = listed().map(function (item) { return item.el; }).filter(function (el) {
      return wantField ? isField(el) : !isField(el) && el.tagName !== "TABLE" && !/^H[1-6]$/.test(el.tagName);
    });
    var named = candidates.map(function (el) { return { el: el, name: name(el).toLowerCase() }; });
    for (var i = 0; i < named.length; i++) if (named[i].name === want) return named[i].el;
    for (var j = 0; j < named.length; j++) if (named[j].name && named[j].name.indexOf(want) >= 0) return named[j].el;
    return null;
  }

  function clickable(el) {
    return el.tagName === "DETAILS" ? el.querySelector("summary") || el : el;
  }

  var NOT_FOUND = { ok: false, notFound: true };

  agent.outline = function () {
    var items = listed();
    var lines = [];
    for (var i = 0; i < items.length && i < MAX_LINES; i++) {
      var refEl = clickable(items[i].el);
      var ref = refEl.getAttribute(REF);
      if (!ref) {
        agent.next += 1;
        ref = "e" + agent.next;
        refEl.setAttribute(REF, ref);
      }
      lines.push("[" + ref + "] " + items[i].line);
    }
    if (items.length > MAX_LINES) lines.push("… " + (items.length - MAX_LINES) + " more");
    return lines.join("\n");
  };

  agent.errors = function () {
    var out = store.errors;
    store.errors = [];
    return out;
  };

  agent.rect = function (target, page, wantField) {
    var el = resolve(target, page, wantField);
    if (!el) return null;
    el = clickable(el);
    var box = el.getBoundingClientRect();
    if (box.bottom < 0 || box.top > innerHeight || box.right < 0 || box.left > innerWidth) {
      el.scrollIntoView({ block: "center", inline: "nearest" });
      box = el.getBoundingClientRect();
    }
    return { x: box.left, y: box.top, w: box.width, h: box.height };
  };

  function mouse(el, type) {
    var box = el.getBoundingClientRect();
    var init = { bubbles: true, cancelable: true, view: window, button: 0,
      clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
    var Ctor = type.indexOf("pointer") === 0 && window.PointerEvent ? PointerEvent : MouseEvent;
    el.dispatchEvent(new Ctor(type, init));
  }

  agent.click = function (target, page) {
    var found = resolve(target, page, false);
    if (!found) return NOT_FOUND;
    var el = clickable(found);
    var label = describeElement(found) || cut(name(el));
    mouse(el, "pointerdown");
    mouse(el, "mousedown");
    if (el.focus) el.focus();
    mouse(el, "pointerup");
    mouse(el, "mouseup");
    el.click();
    return { ok: true, label: label };
  };

  function key(el, type) {
    return el.dispatchEvent(new KeyboardEvent(type, {
      key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true }));
  }

  function setValue(el, text) {
    var proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype
      : el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    // The prototype's setter, so a framework that wraps `value` sees the change.
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
  }

  agent.type = function (target, text, submit, page) {
    var el = resolve(target, page, true);
    if (!el) {
      // A ref to something that is not a field says so, rather than "not found".
      var other = resolve(target, page, false);
      if (other && !isField(other)) {
        return { ok: false, text: "That's a " + (describeElement(other) || "element").split(":")[0] + ", not a field to type in." };
      }
      return NOT_FOUND;
    }
    if (!isField(el)) {
      return { ok: false, text: "That's a " + (describeElement(el) || "element").split(":")[0] + ", not a field to type in." };
    }
    text = String(text == null ? "" : text);
    if (el.focus) el.focus();
    if (el.tagName === "SELECT") {
      var want = text.toLowerCase();
      var option = Array.prototype.find.call(el.options, function (o) {
        return squash(o.textContent).toLowerCase() === want || o.value.toLowerCase() === want;
      });
      if (!option) return { ok: false, text: 'No choice "' + cut(text) + '" in ' + cut(name(el)) + "." };
      setValue(el, option.value);
    } else if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      setValue(el, text);
    } else {
      el.textContent = text;
    }
    el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    var submitted = false;
    if (submit) {
      var go = key(el, "keydown");
      if (go) key(el, "keypress");
      if (go && el.tagName === "INPUT" && el.form) {
        el.form.requestSubmit();
        submitted = true;
      }
      key(el, "keyup");
    }
    return { ok: true, label: describeElement(el) || cut(name(el)), submitted: submitted };
  };

  function where() {
    var scroller = document.scrollingElement || document.documentElement;
    var room = scroller.scrollHeight - scroller.clientHeight;
    if (room <= 0) return "The page fits the viewer; there is nothing to scroll.";
    return "Now " + Math.round((scroller.scrollTop / room) * 100) + "% of the way down the page.";
  }

  agent.scroll = function (directionOrTarget, page) {
    var scroller = document.scrollingElement || document.documentElement;
    var before = scroller.scrollTop;
    var direction = squash(directionOrTarget).toLowerCase();
    if (direction === "up" || direction === "down") {
      scroller.scrollTop += (direction === "down" ? 1 : -1) * Math.round(innerHeight * 0.8);
    } else if (direction === "top") {
      scroller.scrollTop = 0;
    } else if (direction === "bottom") {
      scroller.scrollTop = scroller.scrollHeight;
    } else {
      var el = resolve(directionOrTarget, page, false) || resolve(directionOrTarget, page, true);
      if (!el) return NOT_FOUND;
      clickable(el).scrollIntoView({ block: "center", inline: "nearest" });
      return { ok: true, text: "Scrolled to " + (describeElement(el) || cut(name(el))) + ". " + where() };
    }
    if (scroller.scrollTop === before && direction !== "top" && direction !== "bottom") {
      return { ok: true, text: "Already at the " + (direction === "down" ? "bottom" : "top") + ". " + where() };
    }
    return { ok: true, text: "Scrolled " + direction + ". " + where() };
  };

  window.__porticoAgent = agent;
})();

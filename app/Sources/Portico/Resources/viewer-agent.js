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
  var MARKER = "viewer-agent-4";
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
      var line = event.lineno ? " (line " + event.lineno + ")" : "";
      note((event.message || describe(event.error)) + line);
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

  // MARK: the person's input (v0.14 §6b.4)

  // Whether the person clicked, pressed a key or scrolled with the wheel
  // (`isTrusted`: the browser's own events, never a script's) since the
  // agent's last look. Kept with the errors, so a reinstalled script keeps
  // it and listens once; `outline()` (a look) clears it. Scroll events are
  // not used: the browser marks those trusted even when a script scrolled.
  if (!store.person) {
    store.person = { used: false };
    ["click", "keydown", "wheel"].forEach(function (type) {
      window.addEventListener(type, function (event) {
        if (event.isTrusted) store.person.used = true;
      }, true);
    });
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

  // MARK: a heading inside a clickable card (v0.14 §6b.5)

  var CLICKABLE = "a[href],button,[role=button],[onclick]";

  /// The heading whose text the target is (exactly, then partly), or null.
  function headingNamed(target) {
    var want = squash(target).toLowerCase();
    if (!want || /^e\d+$/.test(want)) return null;
    var headings = listed().map(function (item) { return item.el; }).filter(function (el) {
      return /^H[1-6]$/.test(el.tagName);
    }).map(function (el) { return { el: el, name: name(el).toLowerCase() }; });
    for (var i = 0; i < headings.length; i++) if (headings[i].name === want) return headings[i].el;
    for (var j = 0; j < headings.length; j++) if (headings[j].name && headings[j].name.indexOf(want) >= 0) return headings[j].el;
    return null;
  }

  // An ancestor whose box covers more than this share of the viewport is
  // a page wrapper or a modal backdrop, not the heading's card.
  var MAX_CARD_SHARE = 0.6;

  function coversViewport(el) {
    var box = el.getBoundingClientRect();
    var area = Math.min(box.width, innerWidth) * Math.min(box.height, innerHeight);
    return area > MAX_CARD_SHARE * innerWidth * innerHeight;
  }

  /// Whether something clickable holds `heading` as its card: the heading
  /// itself, or the nearest ancestor that is a link, a button,
  /// `[role=button]`, has an `onclick` attribute or property, or shows
  /// `cursor: pointer`. The search stops (false) at an ancestor holding
  /// another listed heading or covering most of the viewport: a list, a
  /// page wrapper or a backdrop is not one card.
  function inClickableCard(heading) {
    var headings = listed().map(function (item) { return item.el; }).filter(function (el) {
      return /^H[1-6]$/.test(el.tagName);
    });
    for (var at = heading; at && at !== document.body && at !== document.documentElement; at = at.parentElement) {
      if (at !== heading) {
        var held = 0;
        for (var i = 0; i < headings.length; i++) if (at.contains(headings[i])) held += 1;
        if (held > 1 || coversViewport(at)) return false;
      }
      if (at.matches(CLICKABLE) || typeof at.onclick === "function") return true;
      if (at !== heading && getComputedStyle(at).cursor === "pointer") return true;
    }
    return false;
  }

  /// What a click target names: `{el}` to click (`found`, what it was found
  /// as), `{heading: true}` for a heading not in a clickable card, or null.
  /// Anything the outline can click by its words is found first, as
  /// before; only then a heading, which is clicked itself so the click
  /// bubbles to its card as a person's would (delegated handlers see the
  /// heading as the target; a link around it still follows).
  function clickTarget(target, page) {
    var el = resolve(target, page, false);
    if (el) return { el: clickable(el), found: el };
    var heading = headingNamed(target);
    if (!heading) return null;
    return inClickableCard(heading) ? { el: heading, found: heading } : { heading: true };
  }

  var NOT_FOUND = { ok: false, notFound: true };

  /// Where the page is: scheme and host (with port). The app checks a
  /// page's site before a click or typing and passes this along; if the
  /// page has gone elsewhere meanwhile (a redirect, a timer), the action
  /// is refused for the new site rather than done there.
  agent.place = function () {
    return location.protocol + "//" + location.host;
  };

  function moved(place) {
    if (!place || agent.place() === place) return null;
    return { ok: false, outside: location.host || location.href };
  }

  agent.outline = function () {
    store.person.used = false;
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

  agent.personUsed = function () {
    return store.person.used;
  };

  agent.errors = function () {
    var out = store.errors;
    store.errors = [];
    return out;
  };

  agent.rect = function (target, page, wantField) {
    var el;
    if (wantField) {
      el = resolve(target, page, true);
      if (!el) return null;
      el = clickable(el);
    } else {
      var picked = clickTarget(target, page);
      if (!picked) return null;
      if (picked.heading) return { heading: true };
      el = picked.el;
    }
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

  agent.click = function (target, page, place) {
    var away = moved(place);
    if (away) return away;
    var picked = clickTarget(target, page);
    if (!picked) return NOT_FOUND;
    if (picked.heading) return { ok: false, heading: true };
    var found = picked.found;
    var el = picked.el;
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

  agent.type = function (target, text, submit, page, place) {
    var away = moved(place);
    if (away) return away;
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

  // MARK: marks (v0.14, spec §3.1, §6)

  // Numbered accent boxes with a short note, drawn over page elements in
  // one `<portico-marks>` host with its own shadow root, so the page's
  // styles do not reach in and clicks pass through to the page.
  var MARKS_HOST = "portico-marks";
  var MARK_FALLBACK_ACCENT = "#0a84ff";
  var MARKS_STYLE =
    ".box{position:absolute;box-sizing:border-box;border:2px solid var(--accent);border-radius:6px;" +
    "margin:0;padding:0;background:none;pointer-events:none}" +
    ".badge{position:absolute;left:-11px;top:-11px;width:18px;height:18px;border-radius:50%;" +
    "background:var(--accent);color:#fff;font:bold 11px/18px -apple-system,system-ui,sans-serif;" +
    "text-align:center;letter-spacing:normal;text-transform:none}" +
    ".note{position:absolute;top:-2px;left:0;box-sizing:border-box;max-width:none;white-space:nowrap;" +
    "overflow:hidden;text-overflow:ellipsis;" +
    "background:var(--accent);color:#fff;font:12px/16px -apple-system,system-ui,sans-serif;" +
    "border-radius:5px;padding:2px 7px;letter-spacing:normal;text-transform:none}";

  // After the marks are drawn, the page is watched for a short while: a
  // page that builds its content with script (a single-page app) adds a
  // marked element after the load, and content added above a mark moves
  // it. Changes are gathered and handled at most every WATCH_GAP ms, and
  // the watch ends WATCH_MS after the marks were shown.
  var WATCH_MS = 2000;
  var WATCH_GAP = 60;
  var CLIPS = /^(hidden|auto|scroll|clip|overlay)$/;

  var marks = { host: null, root: null, items: [], observer: null, wanted: [],
    watch: null, watchEnd: 0, watchTimer: null, pending: null };

  /// `body > tag:nth-of-type(n) > …`: where the element sits under `body`,
  /// or "" when it is not under `body`.
  function pathOf(el) {
    var parts = [];
    while (el && el !== document.body) {
      var parent = el.parentElement;
      if (!parent) return "";
      var n = 1;
      for (var s = el.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === el.tagName) n += 1;
      parts.unshift(el.tagName.toLowerCase() + ":nth-of-type(" + n + ")");
      el = parent;
    }
    if (!el) return "";
    parts.unshift("body");
    return parts.join(" > ");
  }

  /// Any listed element may be marked: by ref on its page, or by name
  /// (exactly, then partly) — no field/non-field filter as for clicks;
  /// failing those, any visible text (v0.17 §3.3).
  function markTarget(target, page) {
    target = squash(target);
    if (!target) return null;
    if (/^e\d+$/.test(target)) return resolve(target, page, false);
    var want = target.toLowerCase();
    var named = listed().map(function (item) { return { el: item.el, name: name(item.el).toLowerCase() }; });
    for (var i = 0; i < named.length; i++) if (named[i].name === want) return named[i].el;
    for (var j = 0; j < named.length; j++) if (named[j].name && named[j].name.indexOf(want) >= 0) return named[j].el;
    return visibleTextTarget(want);
  }

  var NO_TEXT = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, HEAD: 1 };
  // A text candidate whose box covers more than this share of the
  // viewport is a page wrapper, not the thing meant.
  var MAX_TEXT_SHARE = 0.8;

  function textOf(el) {
    return squash(el.innerText).toLowerCase();
  }

  /// Whether `el` may be the element some text is marked by: visible,
  /// with a size, and not a wrapper around most of the view.
  function textCandidate(el) {
    if (!visible(el)) return false;
    var box = el.getBoundingClientRect();
    if (!box.width || !box.height) return false;
    var area = Math.min(box.width, innerWidth) * Math.min(box.height, innerHeight);
    return area <= MAX_TEXT_SHARE * innerWidth * innerHeight;
  }

  /// The innermost visible element under `body` whose text (spaces
  /// collapsed, lower case) contains `want`: of those that do, the first
  /// in document order with no element child that also does. Never
  /// `html`, `body`, the marks overlay, an element with no size or a
  /// wrapper around most of the view, so text only the whole page holds
  /// (across two paragraphs) is no match. An element whose text lacks
  /// `want` is passed over with everything inside it.
  function visibleTextTarget(want) {
    if (!want || !document.body) return null;
    var kept = new Set();
    var order = [];
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (el) {
        if (NO_TEXT[el.tagName] || el.nodeName.toLowerCase() === MARKS_HOST) return NodeFilter.FILTER_REJECT;
        if (textOf(el).indexOf(want) < 0) return NodeFilter.FILTER_REJECT;
        return textCandidate(el) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      }
    });
    for (var el = walker.nextNode(); el; el = walker.nextNode()) {
      kept.add(el);
      order.push(el);
    }
    for (var i = 0; i < order.length; i++) {
      var inner = true;
      for (var c = order[i].firstElementChild; c && inner; c = c.nextElementSibling) {
        if (kept.has(c)) inner = false;
      }
      if (inner) return order[i];
    }
    return null;
  }

  /// The element a saved locator names on this page, or null: its path if
  /// the tag (and text, when there is one) still match, else the first
  /// element of that tag whose text is the same.
  function findAgain(locator) {
    if (!locator || !locator.tag) return null;
    var tag = String(locator.tag).toLowerCase();
    var text = locator.text == null ? "" : String(locator.text);
    var el = null;
    if (locator.path) {
      try { el = document.querySelector(String(locator.path)); } catch (e) { el = null; }
    }
    if (el && el.tagName.toLowerCase() === tag && (!text || cut(name(el)) === text)) return el;
    // With no text there is nothing to tell one element of the tag from another.
    if (!text) return null;
    var all = document.getElementsByTagName(tag);
    for (var i = 0; i < all.length; i++) if (cut(name(all[i])) === text) return all[i];
    return null;
  }

  /// The note to the right of the box, or to its left when there is no
  /// room; failing both, kept inside the page's width (cut with "…" when
  /// wider than it), so a mark never adds a horizontal scrollbar.
  function placeNote(note, r, width) {
    var GAP = 6;
    note.style.maxWidth = "none";
    var w = note.offsetWidth;
    var x;
    if (r.right + GAP + w <= width) {
      x = r.right + GAP;
    } else if (r.left - GAP - w >= 0) {
      x = r.left - GAP - w;
    } else if (w > width) {
      note.style.maxWidth = Math.max(0, width) + "px";
      x = 0;
    } else {
      x = Math.max(0, Math.min(r.right + GAP, width - w));
    }
    // Relative to the box's padding edge, inside its 2 px border.
    note.style.left = (x - r.left - 2) + "px";
  }

  /// Whether `r` (the element's rect) lies wholly outside an ancestor that
  /// clips its overflow (a phone frame's scrolling screen): its mark would
  /// float outside that frame. The document itself is not such an
  /// ancestor, nor `body` when its overflow is the viewport's.
  function clippedAway(el, r) {
    var html = document.documentElement;
    var hs = getComputedStyle(html);
    var bodyIsViewport = hs.overflowX === "visible" && hs.overflowY === "visible";
    for (var a = el.parentElement; a && a !== html; a = a.parentElement) {
      if (a === document.body && bodyIsViewport) continue;
      var s = getComputedStyle(a);
      var clipX = CLIPS.test(s.overflowX);
      var clipY = CLIPS.test(s.overflowY);
      if (!clipX && !clipY) continue;
      // The padding box: what the ancestor clips to, inside its border.
      var b = a.getBoundingClientRect();
      var top = b.top + a.clientTop;
      var left = b.left + a.clientLeft;
      var c = { top: top, left: left, bottom: top + a.clientHeight, right: left + a.clientWidth };
      if (clipY && (r.bottom <= c.top || r.top >= c.bottom)) return true;
      if (clipX && (r.right <= c.left || r.left >= c.right)) return true;
    }
    return false;
  }

  // A badge's square and where `.badge` puts it: 11 px out from the box's
  // padding edge, inside its 2 px border. A badge meeting an earlier one
  // moves right by BADGE_STEP until clear (Ruling 12).
  var BADGE_SIZE = 18;
  var BADGE_OUT = 11;
  var BOX_BORDER = 2;
  var BADGE_STEP = 22;

  /// Page coordinates of each badge's top-left for `boxes` ([{left, top,
  /// width, height}], in mark-number order), in the order given: each at
  /// its box's corner, moved right past any earlier badge it would meet.
  agent.badgeSpots = function (boxes) {
    var spots = [];
    for (var i = 0; i < boxes.length; i++) {
      var spot = { x: boxes[i].left + BOX_BORDER - BADGE_OUT, y: boxes[i].top + BOX_BORDER - BADGE_OUT };
      var bumped = true;
      while (bumped) {
        bumped = false;
        for (var j = 0; j < spots.length; j++) {
          if (Math.abs(spot.x - spots[j].x) < BADGE_SIZE && Math.abs(spot.y - spots[j].y) < BADGE_SIZE) {
            spot.x += BADGE_STEP;
            bumped = true;
          }
        }
      }
      spots.push(spot);
    }
    return spots;
  };

  function placeMarks() {
    if (!marks.host) return;
    var origin = marks.host.getBoundingClientRect();
    var width = document.documentElement.clientWidth;
    var shown = [];
    for (var i = 0; i < marks.items.length; i++) {
      var item = marks.items[i];
      var r = item.el.getBoundingClientRect();
      // The badge and note are inside the box and go with it.
      if (!item.el.isConnected || (!r.width && !r.height) || clippedAway(item.el, r)) {
        item.box.style.display = "none";
        continue;
      }
      var left = r.left - origin.left;
      var top = r.top - origin.top;
      item.box.style.display = "";
      item.box.style.left = left + "px";
      item.box.style.top = top + "px";
      item.box.style.width = r.width + "px";
      item.box.style.height = r.height + "px";
      if (item.note) placeNote(item.note, r, width);
      shown.push({ item: item, box: { left: left, top: top, width: r.width, height: r.height } });
    }
    shown.sort(function (a, b) { return Number(a.item.n) - Number(b.item.n); });
    var spots = agent.badgeSpots(shown.map(function (s) { return s.box; }));
    for (var k = 0; k < shown.length; k++) {
      // Relative to the box's padding edge, as `.badge`'s own left and top are.
      shown[k].item.badge.style.left = (spots[k].x - shown[k].box.left - BOX_BORDER) + "px";
      shown[k].item.badge.style.top = (spots[k].y - shown[k].box.top - BOX_BORDER) + "px";
    }
  }

  function endWatch() {
    if (marks.watch) marks.watch.disconnect();
    if (marks.watchTimer) clearTimeout(marks.watchTimer);
    if (marks.pending) clearTimeout(marks.pending);
    marks.watch = null;
    marks.watchTimer = null;
    marks.pending = null;
  }

  function stopMarks() {
    endWatch();
    if (marks.observer) marks.observer.disconnect();
    window.removeEventListener("scroll", placeMarks, true);
    window.removeEventListener("resize", placeMarks);
    marks.host = null;
    marks.root = null;
    marks.items = [];
    marks.observer = null;
    marks.wanted = [];
  }

  agent.markLocate = function (target, page) {
    var el = markTarget(target, page);
    if (!el) return NOT_FOUND;
    return {
      ok: true,
      label: describeElement(el) || cut(name(el)),
      locator: { path: pathOf(el), tag: el.tagName.toLowerCase(), text: cut(name(el)) }
    };
  };

  agent.hideMarks = function () {
    stopMarks();
    // Every host, including one an earlier copy of this script drew.
    Array.prototype.forEach.call(document.querySelectorAll(MARKS_HOST), function (host) {
      if (host.parentNode) host.parentNode.removeChild(host);
    });
  };

  /// The overlay's host, made on first need.
  function ensureHost(accent) {
    if (marks.host) return;
    var host = document.createElement(MARKS_HOST);
    host.setAttribute("aria-hidden", "true");
    host.style.cssText = "position:absolute!important;top:0!important;left:0!important;width:0!important;" +
      "height:0!important;margin:0!important;padding:0!important;border:0!important;display:block!important;" +
      "pointer-events:none!important;z-index:2147483647!important;transform:none!important";
    host.style.setProperty("--accent", MARK_FALLBACK_ACCENT);
    if (typeof accent === "string" && accent) host.style.setProperty("--accent", accent);
    var root = host.attachShadow({ mode: "open" });
    var style = document.createElement("style");
    style.textContent = MARKS_STYLE;
    root.appendChild(style);
    document.documentElement.appendChild(host);
    marks.host = host;
    marks.root = root;
    if (window.ResizeObserver) marks.observer = new ResizeObserver(placeMarks);
  }

  /// A box (badge, note) for `mark` ({n, note}) over `el`.
  function addItem(mark, el, accent) {
    ensureHost(accent);
    var box = document.createElement("div");
    box.className = "box";
    var badge = document.createElement("div");
    badge.className = "badge";
    badge.textContent = String(mark.n);
    box.appendChild(badge);
    var note = null;
    if (mark.note) {
      note = document.createElement("div");
      note.className = "note";
      note.textContent = String(mark.note);
      box.appendChild(note);
    }
    marks.root.appendChild(box);
    var item = { n: mark.n, el: el, box: box, badge: badge, note: note };
    marks.items.push(item);
    if (marks.observer) marks.observer.observe(el);
    return item;
  }

  function itemFor(n) {
    for (var i = 0; i < marks.items.length; i++) if (String(marks.items[i].n) === String(n)) return marks.items[i];
    return null;
  }

  /// Find again what is missing (never found, or taken out of the page
  /// and built again), then place every box.
  function refreshMarks() {
    for (var i = 0; i < marks.wanted.length; i++) {
      var want = marks.wanted[i];
      var item = itemFor(want.n);
      if (item && item.el.isConnected) continue;
      var el = findAgain(want.locator);
      if (!el) continue;
      if (item) {
        if (marks.observer) { marks.observer.unobserve(item.el); marks.observer.observe(el); }
        item.el = el;
      } else {
        addItem(want, el, want.accent);
      }
    }
    placeMarks();
  }

  /// A change the overlay made itself (its host going in or out).
  function ours(record) {
    if (marks.host && (record.target === marks.host || marks.host.contains(record.target))) return true;
    if (record.type !== "childList") return false;
    var nodes = Array.prototype.slice.call(record.addedNodes).concat(Array.prototype.slice.call(record.removedNodes));
    return nodes.length > 0 && nodes.every(function (node) {
      return node.nodeName && node.nodeName.toLowerCase() === MARKS_HOST;
    });
  }

  function startWatch() {
    endWatch();
    if (!window.MutationObserver || !marks.wanted.length) return;
    marks.watchEnd = Date.now() + WATCH_MS;
    marks.watch = new MutationObserver(function (records) {
      if (records.every(ours) || marks.pending) return;
      marks.pending = setTimeout(function () {
        marks.pending = null;
        if (Date.now() <= marks.watchEnd) refreshMarks();
      }, WATCH_GAP);
    });
    marks.watch.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
    marks.watchTimer = setTimeout(endWatch, WATCH_MS);
  }

  /// Draw `list` ([{n, note, locator}]) in `accent`, replacing any earlier
  /// marks; an empty list only clears. Answers [{n, found}] in list order.
  /// A mark not found now may still be drawn during the watch; `markStatus`
  /// says which are on the page then.
  agent.showMarks = function (list, accent) {
    agent.hideMarks();
    list = list || [];
    var results = [];
    for (var i = 0; i < list.length; i++) {
      if (!list[i]) continue;
      var want = { n: list[i].n, note: list[i].note, locator: list[i].locator, accent: accent };
      marks.wanted.push(want);
      var el = findAgain(want.locator);
      results.push({ n: want.n, found: !!el });
      if (el) addItem(want, el, accent);
    }
    if (!marks.wanted.length) return results;
    // Capture phase, so an inner scroller's scroll (which does not bubble) counts.
    window.addEventListener("scroll", placeMarks, true);
    window.addEventListener("resize", placeMarks);
    startWatch();
    placeMarks();
    return results;
  };

  /// [{n, found}] for the marks shown, as they stand on the page now.
  agent.markStatus = function () {
    return marks.wanted.map(function (want) {
      var item = itemFor(want.n);
      return { n: want.n, found: !!item && item.el.isConnected };
    });
  };

  agent.scrollToMark = function (n) {
    for (var i = 0; i < marks.items.length; i++) {
      var item = marks.items[i];
      if (String(item.n) !== String(n)) continue;
      if (!item.el.isConnected) return false;
      item.el.scrollIntoView({ block: "center", inline: "nearest" });
      placeMarks();
      return true;
    }
    return false;
  };

  window.__porticoAgent = agent;
})();

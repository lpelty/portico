/*
  Comments in the rendered Markdown page and the editor (v0.23).

  Comment format v1 (protocol/COMMENTS.md) keeps comments in the file as HTML
  comments, which the renderer passes through as Comment nodes. This script:
  - highlights the text between each <!--c:ID--> / <!--/c:ID--> pair in a
    <mark class="pc-anchor" data-c="ID">, with pc-open when its thread
    (<!--co:ID ... status:open ...>) is open; overlapping anchors nest;
  - reports the person's selection, snapped to whole words, with its block's
    source lines and which occurrence of the text in the block it is, or why
    it can't be anchored;
  - draws the comments margin from the state the app pushes (render), and
    posts the person's actions to the app's "comments" handler.
  The app owns the state; this page draws only what it is given.
*/
(function () {
  "use strict";

  var OPEN = /^c:([a-z0-9]{5,8})$/;
  var CLOSE = /^\/c:([a-z0-9]{5,8})$/;
  var BLOCK = /^co:([a-z0-9]{5,8})(?=[\s]|$)/;

  function isWordChar(ch) {
    return !!ch && /[\p{L}\p{N}_]/u.test(ch);
  }

  // A word character, or ' / ’ between two of them (format v1's word rule).
  function wordAt(text, i) {
    if (i < 0 || i >= text.length) return false;
    var ch = text[i];
    if (isWordChar(ch)) return true;
    if (ch === "'" || ch === "’") return isWordChar(text[i - 1]) && isWordChar(text[i + 1]);
    return false;
  }

  function comments(root) {
    var out = [];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    var n;
    while ((n = walker.nextNode())) out.push(n);
    return out;
  }

  function textNodesIn(range) {
    var out = [];
    var root = range.commonAncestorContainer;
    if (root.nodeType === Node.TEXT_NODE) return [root];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var n;
    while ((n = walker.nextNode())) {
      if (range.intersectsNode(n)) out.push(n);
    }
    return out;
  }

  function wrap(node, className, id) {
    var mark = document.createElement("mark");
    mark.className = className;
    if (id) mark.setAttribute("data-c", id);
    node.parentNode.insertBefore(mark, node);
    mark.appendChild(node);
    return mark;
  }

  // Wrap the text inside range (splitting the end nodes) in marks.
  function wrapRange(range, className, id) {
    var nodes = textNodesIn(range);
    var marks = [];
    nodes.forEach(function (node) {
      var start = node === range.startContainer ? range.startOffset : 0;
      var end = node === range.endContainer ? range.endOffset : node.data.length;
      if (end <= start) return;
      if (!/\S/.test(node.data.slice(start, end)) && node.parentNode && /^(UL|OL|TABLE|TBODY|TR)$/.test(node.parentNode.nodeName)) return;
      var target = node;
      if (end < target.data.length) target.splitText(end);
      if (start > 0) target = target.splitText(start);
      marks.push(wrap(target, className, id));
    });
    return marks;
  }

  // A thread header's fields (key:value or key:"…"); the first of a duplicated key wins.
  function headerFields(header) {
    var out = {};
    var i = 0, b = header.length;
    var unq = function (v) { return v.replace(/\\([\\">])/g, "$1"); };
    while (i < b) {
      while (i < b && (header[i] === " " || header[i] === "\t")) i++;
      if (i >= b) break;
      var m = /^([A-Za-z_][A-Za-z0-9_-]*):/.exec(header.slice(i));
      if (!m) { while (i < b && header[i] !== " " && header[i] !== "\t") i++; continue; }
      var key = m[1], value;
      i += m[0].length;
      if (header[i] === '"') {
        var j = i + 1;
        while (j < b && header[j] !== '"') j += header[j] === "\\" && j + 1 < b ? 2 : 1;
        value = unq(header.slice(i + 1, Math.min(j, b)));
        i = j + 1;
      } else {
        var k = i;
        while (k < b && header[k] !== " " && header[k] !== "\t") k++;
        value = unq(header.slice(i, k));
        i = k;
      }
      if (!(key in out)) out[key] = value;
    }
    return out;
  }

  function threadStatuses(root) {
    var status = {};
    comments(root).forEach(function (c) {
      var m = BLOCK.exec(c.data);
      if (!m) return;
      var header = c.data.slice(m[0].length).split("\n")[0].replace(/\r$/, "");
      status[m[1]] = headerFields(header).status === "resolved" ? "resolved" : "open";
    });
    return status;
  }

  // The renderer saw comment markers as private-use sentinels (MarkdownPage):
  // U+E000 id U+E001 opens, U+E002 id U+E001 closes. Back to markers.
  function restoreMarkers(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var nodes = [];
    var n;
    while ((n = walker.nextNode())) if (/[\uE000\uE002]/.test(n.data)) nodes.push(n);
    nodes.forEach(function (node) {
      var re = /([\uE000\uE002])([a-z0-9]{5,8})\uE001/g;
      var data = node.data, last = 0, m, frag = document.createDocumentFragment();
      while ((m = re.exec(data))) {
        if (m.index > last) frag.appendChild(document.createTextNode(data.slice(last, m.index)));
        frag.appendChild(document.createComment((m[1] === "\uE002" ? "/c:" : "c:") + m[2]));
        last = m.index + m[0].length;
      }
      if (last < data.length) frag.appendChild(document.createTextNode(data.slice(last)));
      node.parentNode.replaceChild(frag, node);
    });
    // The file's own private-use characters were escaped (U+E003 and a digit): put them back.
    var w2 = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var t2;
    while ((t2 = w2.nextNode())) {
      if (t2.data.indexOf("\uE003") >= 0) {
        t2.data = t2.data.replace(/\uE003([0-3])/g, function (_, d) { return String.fromCharCode(0xE000 + Number(d)); });
      }
    }
  }

  function highlight(root) {
    root = root || document.body;
    var status = threadStatuses(root);
    var opens = {};
    var pairs = [];
    comments(root).forEach(function (c) {
      var m = OPEN.exec(c.data);
      if (m) { if (!opens[m[1]]) opens[m[1]] = c; return; }
      m = CLOSE.exec(c.data);
      if (m && opens[m[1]]) { pairs.push([m[1], opens[m[1]], c]); delete opens[m[1]]; }
    });
    // Outer anchors first, so an anchor inside another nests inside its mark.
    pairs.sort(function (x, y) {
      return x[1].compareDocumentPosition(y[1]) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
    });
    pairs.forEach(function (p) {
      var range = document.createRange();
      range.setStartAfter(p[1]);
      range.setEndBefore(p[2]);
      var cls = "pc-anchor" + (status[p[0]] === "open" ? " pc-open" : "");
      wrapRange(range, cls, p[0]);
    });
    return pairs.length;
  }

  // --- the selection ---------------------------------------------------------

  // Scripts written without spaces between words: a selection there is
  // anchored exactly as made (the same ranges as CommentFormat.swift).
  function noSpaceAt(text, i) {
    var c = text.codePointAt(i);
    if (c === undefined) return false;
    if (c >= 0xDC00 && c <= 0xDFFF && i > 0) c = text.codePointAt(i - 1);
    return (c >= 0x0E00 && c <= 0x0EFF) || (c >= 0x1000 && c <= 0x109F) || (c >= 0x1780 && c <= 0x17FF) ||
      (c >= 0x3040 && c <= 0x30FF) || (c >= 0x31F0 && c <= 0x31FF) || (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF66 && c <= 0xFF9F) ||
      (c >= 0x20000 && c <= 0x2FFFF);
  }

  function markAt(text, i) {
    var ch = text[i];
    return !!ch && (/\p{M}/u.test(ch) || ch === "\u200D" || (ch >= "\uFE00" && ch <= "\uFE0F"));
  }

  function selWordAt(text, i) {
    return (wordAt(text, i) || markAt(text, i)) && !noSpaceAt(text, i);
  }

  // A selection snaps to whole words, except in scripts without word spaces,
  // and an end never splits a base character from its combining marks.
  // Grapheme cluster boundaries of a text (a skin-toned emoji, a family, a
  // flag, a letter with its accents are one each).
  var segmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
  function graphemeSnap(t, s, e) {
    if (!segmenter) {
      while (s > 0 && markAt(t, s)) s--;
      while (e < t.length && markAt(t, e)) e++;
      return [s, e];
    }
    var bounds = [];
    for (var seg of segmenter.segment(t)) bounds.push(seg.index);
    bounds.push(t.length);
    var a = 0, b = t.length;
    for (var i = 0; i < bounds.length; i++) {
      if (bounds[i] <= s) a = bounds[i];
      if (bounds[i] >= e) { b = bounds[i]; break; }
    }
    return [a, Math.max(a, b)];
  }

  function snapEdges(t, s, e) {
    var g = graphemeSnap(t, s, e);
    s = g[0]; e = g[1];
    while (s > 0 && selWordAt(t, s - 1) && selWordAt(t, s)) s--;
    while (e < t.length && selWordAt(t, e) && selWordAt(t, e - 1)) e++;
    return graphemeSnap(t, s, e);
  }

  function snapRange(range) {
    var r = range.cloneRange();
    if (r.startContainer.nodeType === Node.TEXT_NODE) {
      var t = r.startContainer.data;
      r.setStart(r.startContainer, snapEdges(t, r.startOffset, r.startOffset)[0]);
    }
    if (r.endContainer.nodeType === Node.TEXT_NODE) {
      var u = r.endContainer.data;
      r.setEnd(r.endContainer, snapEdges(u, r.endOffset, r.endOffset)[1]);
    }
    return r;
  }

  function elementOf(node) {
    return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  }

  function blockOf(node) {
    var el = elementOf(node);
    while (el && el !== document.body) {
      if (el.hasAttribute && el.hasAttribute("data-lines")) return el;
      el = el.parentElement;
    }
    return null;
  }

  function closestOf(node, selector) {
    var el = elementOf(node);
    return el ? el.closest(selector) : null;
  }

  function norm(s) {
    return s.replace(/\s+/g, " ");
  }

  function countBefore(hay, needle, before) {
    var n = 0, i = hay.indexOf(needle);
    while (i >= 0 && i < before) {
      n++;
      i = hay.indexOf(needle, i + needle.length);
    }
    return n;
  }

  var lastRange = null;

  function selectionInfo() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
    var range = snapRange(sel.getRangeAt(0));
    lastRange = range;
    var text = norm(range.toString()).trim();
    if (!text) return null;
    var info = { text: text, lines: null, occurrence: 0 };
    var ignored = "pre, code, table, .properties, details.fm";
    if (closestOf(range.startContainer, ignored) || closestOf(range.endContainer, ignored)) {
      info.refusal = "ignored";
      return info;
    }
    var a = blockOf(range.startContainer), b = blockOf(range.endContainer);
    if (!a || a !== b) { info.refusal = "crosses"; return info; }
    if (closestOf(range.startContainer, "li, p") !== closestOf(range.endContainer, "li, p")) {
      info.refusal = "crosses";
      return info;
    }
    var lines = a.getAttribute("data-lines").split("-").map(Number);
    info.lines = lines;
    // Occurrences count visible text only, as the source search does: text in code isn't counted.
    var whole = "", prefix = "", reached = false;
    var walker = document.createTreeWalker(a, NodeFilter.SHOW_TEXT);
    var node;
    while ((node = walker.nextNode())) {
      var inCode = node.parentElement && node.parentElement.closest("code, pre");
      if (!reached && node === range.startContainer) {
        if (!inCode) prefix = whole + node.data.slice(0, range.startOffset);
        else prefix = whole;
        reached = true;
      } else if (!reached && range.startContainer.nodeType !== Node.TEXT_NODE &&
                 (range.comparePoint(node, 0) >= 0)) {
        prefix = whole;
        reached = true;
      }
      if (!inCode) whole += node.data;
    }
    if (!reached) prefix = whole;
    info.occurrence = countBefore(norm(whole), text, norm(prefix).length);
    return info;
  }

  function markDraft() {
    if (api.hooks) return api.hooks.markDraft();
    clearDraft();
    if (!lastRange) return 0;
    return wrapRange(lastRange, "pc-draft").length;
  }

  function clearDraft() {
    if (api.hooks) return api.hooks.clearDraft();
    document.querySelectorAll("mark.pc-draft").forEach(function (m) {
      var parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
      parent.normalize();
    });
  }

  // --- the margin --------------------------------------------------------------

  var state = null;
  var expanded = {};
  var lastActive = null;
  var natural = 0;

  function post(message) {
    if (api.post) return api.post(message);
    try { window.webkit.messageHandlers.comments.postMessage(message); } catch (e) { /* no app */ }
  }

  // Text starts 44 px from the left (#content's 12 px margin and 32 px
  // padding); 24 px from the column to the cards; 16 px right inset. Cards are
  // 276–300 px; the column narrows to 420 px before the cards shrink, and below
  // that the cards keep 276 and the column takes the rest.
  function layout(viewWidth, naturalColumn) {
    var avail = viewWidth - 84;
    if (avail >= naturalColumn + 300) return { column: naturalColumn, card: 300 };
    if (avail >= 420 + 300) return { column: avail - 300, card: 300 };
    if (avail >= 420 + 276) return { column: 420, card: avail - 420 };
    return { column: Math.max(avail - 276, 0), card: 276 };
  }

  // Each card at its wanted top, pushed down to clear the one above by 8 px.
  function stack(tops, heights) {
    var out = [];
    var floor = -Infinity;
    for (var i = 0; i < tops.length; i++) {
      var top = Math.max(tops[i], floor);
      out.push(top);
      floor = top + heights[i] + 8;
    }
    return out;
  }

  function content() { return api.contentElement ? api.contentElement() : document.getElementById("content"); }

  function naturalColumn() {
    if (natural) return natural;
    var probe = document.createElement("div");
    probe.style.cssText = "position:absolute;visibility:hidden;width:76ch;";
    (content() || document.body).appendChild(probe);
    natural = probe.getBoundingClientRect().width || 600;
    probe.remove();
    return natural;
  }

  function docTop(el) {
    var rects = el.getClientRects();
    var r = rects.length ? rects[0] : el.getBoundingClientRect();
    return r.top + window.scrollY;
  }

  function anchorTop(id) {
    if (api.anchorTop) return api.anchorTop(id);
    var mark = document.querySelector('mark.pc-anchor[data-c="' + id + '"]');
    return mark ? docTop(mark) : null;
  }

  function draftTop() {
    if (api.draftTop) return api.draftTop();
    var mark = document.querySelector("mark.pc-draft");
    return mark ? docTop(mark) : null;
  }

  function marksFor(id) {
    return document.querySelectorAll('mark.pc-anchor[data-c="' + id + '"]');
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function head(author, initial, agent, extra) {
    var h = el("div", "pc-head");
    h.appendChild(el("span", "pc-avatar" + (agent ? " pc-agent" : ""), initial));
    h.appendChild(el("b", "pc-name", author));
    if (extra) h.appendChild(el("span", "pc-time", extra));
    return h;
  }

  function replyNode(r) {
    var d = el("div", "pc-reply");
    d.appendChild(head(r.author, r.initial, r.agent, r.time));
    d.appendChild(el("div", "pc-text", r.text));
    return d;
  }

  function field(placeholder, onEnter, onEscape) {
    var t = el("textarea", "pc-field");
    t.rows = 1;
    t.placeholder = placeholder;
    if (state.readOnly) { t.disabled = true; t.title = state.readOnly; }
    t.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (t.value.trim()) onEnter(t.value);
      } else if (e.key === "Escape") {
        e.preventDefault();
        onEscape();
      }
    });
    t.addEventListener("input", function () { t.style.height = "auto"; t.style.height = t.scrollHeight + "px"; });
    return t;
  }

  function button(cls, text, onClick, title) {
    var b = el("button", cls, text);
    b.type = "button";
    if (state.readOnly) { b.disabled = true; b.title = state.readOnly; } else if (title) { b.title = title; }
    b.addEventListener("click", function (e) { e.stopPropagation(); onClick(); });
    return b;
  }

  function firstWords(text, n) {
    var words = (text || "").split(/\s+/).filter(Boolean);
    return words.slice(0, n).join(" ") + (words.length > n ? "…" : "");
  }

  function cardFor(t) {
    var card = el("div", "pc-card");
    card.setAttribute("data-id", t.id);
    var active = state.activeID === t.id;
    if (t.status === "resolved") {
      card.classList.add("pc-resolved");
      var label = t.quote || (t.replies[0] ? firstWords(t.replies[0].text, 6) : "");
      var line = el("div", "pc-resolved-line", "✓ " + label + " · Resolved " + (expanded[t.id] ? "⌃" : "⌄"));
      line.addEventListener("click", function (e) {
        e.stopPropagation();
        expanded[t.id] = !expanded[t.id];
        render(state);
      });
      card.appendChild(line);
      if (expanded[t.id]) {
        t.replies.forEach(function (r) { card.appendChild(replyNode(r)); });
        var actions = el("div", "pc-actions");
        actions.appendChild(button("pc-reopen", "Reopen", function () { post({ type: "reopen", id: t.id }); }));
        card.appendChild(actions);
      }
    } else {
      if (t.orphan) card.appendChild(el("div", "pc-orphan-note", "Text no longer found"));
      t.replies.forEach(function (r) { card.appendChild(replyNode(r)); });
      if (active) {
        card.classList.add("pc-active");
        card.appendChild(field("Reply", function (text) { post({ type: "reply", id: t.id, text: text }); },
          function () { post({ type: "activate", id: null }); }));
        var row = el("div", "pc-actions");
        row.appendChild(button("pc-resolve", "✓ Resolve", function () { post({ type: "resolve", id: t.id }); }));
        card.appendChild(row);
        if (state.error) card.appendChild(el("div", "pc-error", state.error));
      }
    }
    card.addEventListener("mouseenter", function () {
      marksFor(t.id).forEach(function (m) { m.classList.add("pc-hot"); });
    });
    card.addEventListener("mouseleave", function () {
      marksFor(t.id).forEach(function (m) { m.classList.remove("pc-hot"); });
    });
    card.addEventListener("click", function () {
      if (state.activeID !== t.id && t.status !== "resolved") post({ type: "activate", id: t.id });
    });
    return card;
  }

  function draftCard(d) {
    var card = el("div", "pc-card pc-active pc-draft-card");
    card.setAttribute("data-id", "draft");
    card.appendChild(head(d.author, d.initial, false, "· New comment"));
    var input = field("Comment", function (text) { post({ type: "post", text: text }); },
      function () { post({ type: "cancelDraft" }); });
    if (d.text) input.value = d.text;
    card.appendChild(input);
    var row = el("div", "pc-actions");
    row.appendChild(button("pc-cancel", "✕", function () { post({ type: "cancelDraft" }); }, "Cancel (Esc)"));
    row.appendChild(button("pc-post", "✓", function () {
      if (input.value.trim()) post({ type: "post", text: input.value });
    }, "Post (Return)"));
    card.appendChild(row);
    if (state.error) card.appendChild(el("div", "pc-error", state.error));
    return card;
  }

  function render(st) {
    state = st;
    var root = document.documentElement;
    Object.keys(st.theme || {}).forEach(function (k) { root.style.setProperty(k, st.theme[k]); });
    var margin = document.getElementById("pc-margin");
    var box = content();
    // What the person was typing survives a redraw.
    var typing = null;
    if (margin) {
      var f = margin.querySelector(".pc-active .pc-field");
      if (f) typing = { id: f.closest(".pc-card").getAttribute("data-id"), value: f.value, focused: document.activeElement === f };
    }
    if (!st.on) {
      document.body.classList.remove("pc-comments-on");
      if (margin) margin.remove();
      if (box) { box.style.marginLeft = ""; box.style.marginRight = ""; box.style.maxWidth = ""; box.style.width = ""; }
      if (api.onLayout) api.onLayout(null);
      return;
    }
    document.body.classList.add("pc-comments-on");
    var L = layout(document.documentElement.clientWidth, naturalColumn());
    if (box && !api.contentElement) {
      box.style.marginLeft = "12px";
      box.style.marginRight = "0";
      box.style.maxWidth = "none";
      box.style.width = L.column + "px";
    }
    if (api.onLayout) api.onLayout(L);
    if (!margin) {
      margin = el("aside", "");
      margin.id = "pc-margin";
      (api.marginParent ? api.marginParent() : document.body).appendChild(margin);
    }
    margin.style.left = (44 + L.column + 24) + "px";
    margin.style.width = L.card + "px";
    margin.textContent = "";
    var anchored = [], loose = [];
    st.threads.forEach(function (t) {
      var top = t.orphan ? null : anchorTop(t.id);
      (top == null ? loose : anchored).push({ t: t, top: top });
    });
    if (st.draft) {
      var dt = draftTop();
      anchored.push({ draft: st.draft, top: dt == null ? 0 : dt });
    }
    anchored.sort(function (a, b) { return a.top - b.top; });
    var items = anchored.concat(loose);
    if (!items.length) {
      margin.appendChild(el("div", "pc-empty", "No comments. Select text and choose Comment."));
      margin.firstChild.style.top = (box && !api.marginParent ? docTop(box) + 28 : 28) + "px";
      return;
    }
    var nodes = items.map(function (it) {
      var n = it.draft ? draftCard(it.draft) : cardFor(it.t);
      margin.appendChild(n);
      return n;
    });
    var lastAnchored = anchored.length ? anchored[anchored.length - 1].top : (box && !api.marginParent ? docTop(box) + 28 : 28);
    var tops = items.map(function (it) { return it.top == null ? lastAnchored : it.top; });
    var placed = stack(tops, nodes.map(function (n) { return n.getBoundingClientRect().height; }));
    nodes.forEach(function (n, i) { n.style.top = placed[i] + "px"; });
    if (typing) {
      var again = margin.querySelector('.pc-card[data-id="' + typing.id + '"] .pc-field');
      if (again) { again.value = typing.value; if (typing.focused) again.focus(); }
    }
    var draftField = margin.querySelector(".pc-draft-card .pc-field");
    if (draftField && !typing) draftField.focus();
    var activeKey = st.draft ? "draft" : st.activeID;
    if (activeKey && activeKey !== lastActive) {
      var activeCard = margin.querySelector('.pc-card[data-id="' + activeKey + '"]');
      if (activeCard && activeCard.scrollIntoView) activeCard.scrollIntoView({ block: "nearest" });
      var fieldNow = activeCard && activeCard.querySelector(".pc-field");
      if (fieldNow && !st.readOnly) fieldNow.focus();
    }
    lastActive = activeKey || null;
  }

  function innermostMark(target) {
    var t = target && target.nodeType === Node.ELEMENT_NODE ? target : target && target.parentElement;
    return t ? t.closest("mark.pc-anchor") : null;
  }

  document.addEventListener("click", function (e) {
    var m = innermostMark(e.target);
    if (m) post({ type: "anchorClicked", id: m.getAttribute("data-c") });
  });
  document.addEventListener("mouseover", function (e) {
    if (!state || !state.on) return;
    var m = innermostMark(e.target);
    if (!m) return;
    var id = m.getAttribute("data-c");
    if (id !== state.activeID && !state.draft && state.threads.some(function (t) { return t.id === id && t.status === "open"; })) {
      post({ type: "activate", id: id });
    }
  });
  window.addEventListener("resize", function () { if (state) render(state); });

  // The viewer's own menu (Comment, Cut, Copy, Paste, Select All) replaces WebKit's.
  document.addEventListener("contextmenu", function (e) {
    if (api.ownMenu === false) return;
    e.preventDefault();
    post({ type: "menu", x: e.clientX, y: e.clientY, selection: selectionInfo() });
  });

  var api = {
    highlight: highlight,
    selectionInfo: selectionInfo,
    markDraft: markDraft,
    clearDraft: clearDraft,
    wordAt: wordAt,
    layout: layout,
    stack: stack,
    render: render,
    post: null
  };
  window.__porticoComments = api;

  // In the editor's page: the editor answers where things are, and draws
  // its own menu and highlights.
  var hooks = window.portico && window.portico.commentHooks;
  if (hooks) {
    api.hooks = hooks;
    api.contentElement = hooks.contentElement;
    api.marginParent = hooks.marginParent;
    api.anchorTop = hooks.anchorTop;
    api.draftTop = hooks.draftTop;
    api.onLayout = hooks.onLayout;
    api.ownMenu = false;
  }

  if (document.getElementById("body")) {
    restoreMarkers(document.getElementById("body"));
    highlight(document.getElementById("body"));
    post({ type: "ready" });
  }
})();

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

  function threadStatuses(root) {
    var status = {};
    comments(root).forEach(function (c) {
      var m = BLOCK.exec(c.data);
      if (!m) return;
      var s = /(?:^|\s)status:(\S+)/.exec(c.data);
      status[m[1]] = s && s[1] === "resolved" ? "resolved" : "open";
    });
    return status;
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

  function snapRange(range) {
    var r = range.cloneRange();
    if (r.startContainer.nodeType === Node.TEXT_NODE) {
      var t = r.startContainer.data, s = r.startOffset;
      while (s > 0 && wordAt(t, s - 1) && wordAt(t, s)) s--;
      r.setStart(r.startContainer, s);
    }
    if (r.endContainer.nodeType === Node.TEXT_NODE) {
      var u = r.endContainer.data, e = r.endOffset;
      while (e < u.length && wordAt(u, e) && wordAt(u, e - 1)) e++;
      r.setEnd(r.endContainer, e);
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
    var before = document.createRange();
    before.setStart(a, 0);
    before.setEnd(range.startContainer, range.startOffset);
    var prefix = norm(before.toString());
    info.occurrence = countBefore(norm(a.textContent), text, prefix.length);
    return info;
  }

  function markDraft() {
    clearDraft();
    if (!lastRange) return 0;
    return wrapRange(lastRange, "pc-draft").length;
  }

  function clearDraft() {
    document.querySelectorAll("mark.pc-draft").forEach(function (m) {
      var parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
      parent.normalize();
    });
  }

  var api = {
    highlight: highlight,
    selectionInfo: selectionInfo,
    markDraft: markDraft,
    clearDraft: clearDraft,
    wordAt: wordAt
  };
  window.__porticoComments = api;

  if (document.getElementById("body")) highlight(document.getElementById("body"));
})();

// Minimal custom right-click/long-press menu: Cut, Copy, Paste only.
//
// Always fully suppresses Firefox's native context menu -- there's no way
// to selectively keep only some of its items, it's all-or-nothing for a
// content script (see preventDefault() below; confirmed live: even with a
// page-text selection, the native menu still surfaces "Take Screenshot",
// "Search Google for ...", "Ask an AI Chatbot", "View Selection Source"
// alongside Copy, none of which can be hidden individually) -- and shows
// this file's own 3-button popup instead. Each button just calls
// document.execCommand('cut'|'copy'|'paste'), the same underlying action
// the native menu's own Cut/Copy/Paste items run, operating on whatever
// the page's current selection or focused field already is -- so this
// needs no Clipboard API / clipboardRead permission wiring of its own.
// Content scripts get execCommand('paste') access ordinary page scripts
// are denied, being part of a trusted, user-installed extension rather
// than arbitrary web content.
//
// This exists because right-click was a real kiosk-escape route:
// Firefox's default context menu includes "Inspect" (dev tools), "View
// Page/Selection Source", "Save Page As", "Print", "Take a Screenshot"
// and more, reaching well outside the kiosk site. (DevTools itself is
// separately closed off via the DisableDeveloperTools policy in
// ../default.nix, which also blocks the F12/Ctrl+Shift+I shortcuts this
// content script has no way to touch.)
//
// Loaded via manifest.json's all_frames:true content_scripts entry
// (alongside nav-guard.js) rather than the top-frame-only one content.js/
// back-button.js use -- confirmed live that right-clicking (or a
// touch-and-hold) on content inside a same-page IFRAME (e.g. an embedded
// YouTube player) shows Firefox's native menu, "Ask an AI Chatbot" and
// all, when this only ran in the top frame. Right-clicking inside such an
// iframe is a real reachable action, not just the top-level page.
(function () {
  "use strict";

  var menu = null;

  function isEditable(el) {
    if (!el) return false;
    if (el.isContentEditable) return true;
    var tag = el.tagName;
    if (tag === "TEXTAREA") return true;
    if (tag === "INPUT") {
      var type = (el.type || "text").toLowerCase();
      return ["text", "search", "email", "tel", "url", "password", "number"].indexOf(type) !== -1;
    }
    return false;
  }

  // Selections inside an <input>/<textarea> live on the element itself
  // (selectionStart/End) and aren't visible to the document Selection
  // API, which only covers regular page content and contenteditable
  // regions -- so this needs its own check per target kind.
  function hasSelection(el) {
    if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA")) {
      return el.selectionStart != null && el.selectionStart !== el.selectionEnd;
    }
    var sel = window.getSelection();
    return !!sel && sel.toString().length > 0;
  }

  function hideMenu() {
    if (menu) {
      menu.remove();
      menu = null;
    }
  }

  function makeButton(label, command) {
    var btn = document.createElement("div");
    btn.textContent = label;
    // 14px vertical padding + ~18px line height works out to roughly a
    // 48px CSS-px tall tap target, matching content.js's on-screen
    // keyboard keys -- see that file's own comment on why 48px (Google
    // Material Design's touch-target minimum) rather than picking a size
    // independently here.
    btn.style.cssText =
      "padding: 14px 26px; font-size: 18px; font-family: sans-serif; color: #fff; cursor: pointer; user-select: none;";
    // Without this, tapping a button blurs the field / clears the
    // selection first -- same reasoning as content.js's own keyboard root.
    btn.addEventListener("mousedown", function (e) {
      e.preventDefault();
    });
    btn.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      document.execCommand(command);
      hideMenu();
    });
    return btn;
  }

  function showMenu(x, y, target) {
    hideMenu();

    var editable = isEditable(target);
    var selected = hasSelection(target);

    var candidate = document.createElement("div");
    if (editable && selected) candidate.appendChild(makeButton("Cut", "cut"));
    if (selected) candidate.appendChild(makeButton("Copy", "copy"));
    if (editable) candidate.appendChild(makeButton("Paste", "paste"));
    if (!candidate.childNodes.length) return; // nothing applicable at this point -- don't show an empty popup

    menu = candidate;
    menu.style.cssText = [
      "position: fixed",
      "z-index: 2147483647",
      "background: #22262b",
      "border: 1px solid #4a505a",
      "border-radius: 8px",
      "box-shadow: 0 2px 10px rgba(0,0,0,0.5)",
      "display: flex",
      "flex-direction: column",
      "overflow: hidden",
    ].join(";");
    document.documentElement.appendChild(menu);

    // Clamp so the menu doesn't overflow past the right/bottom edge.
    var rect = menu.getBoundingClientRect();
    var left = Math.max(4, Math.min(x, window.innerWidth - rect.width - 4));
    var top = Math.max(4, Math.min(y, window.innerHeight - rect.height - 4));
    menu.style.left = left + "px";
    menu.style.top = top + "px";
  }

  document.addEventListener(
    "contextmenu",
    function (e) {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, e.target);
    },
    true
  );

  // Dismiss on any interaction outside the menu itself.
  document.addEventListener(
    "mousedown",
    function (e) {
      if (menu && !menu.contains(e.target)) hideMenu();
    },
    true
  );
  document.addEventListener(
    "touchstart",
    function (e) {
      if (menu && !menu.contains(e.target)) hideMenu();
    },
    true
  );
})();

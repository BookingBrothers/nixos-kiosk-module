// Touch on-screen keyboard for common/configuration/dashboard kiosks
// (enableKeyboard = true). Built and force-installed by that module's
// default.nix -- see there for how/why.
//
// This exists because the compositor (cage) doesn't implement wlr-layer-shell,
// which is what a system-level virtual keyboard (e.g. wvkbd) needs to overlay
// itself on top of a fullscreen client. Doing it here, inside the page, avoids
// that entirely -- to cage this is just ordinary page content of its one
// client (Firefox), not a second surface it needs to know how to stack.
//
// Layout follows the page's declared language (<html lang="...">). Each
// language adds its own special characters on top of a shared QWERTY base,
// placed on the SAME row they sit on on that language's real physical
// keyboard (ROW1_EXTRA/ROW2_EXTRA/ROW3_EXTRA -- e.g. German ü extends
// row2, ö/ä extend row3, ß sits on the number row; Danish å extends row2,
// æ/ø extend row3); German additionally swaps Y/Z to match the real
// QWERTZ layout (ROW2_OVERRIDES/ROW4_OVERRIDES). Only da/de/nl/en are
// covered out of the box -- other languages fall back to plain QWERTY
// (SUPPORTED_LANGS below has no entry, detectLanguage() returns "en"), and
// other locale layout differences (e.g. AZERTY) aren't handled at all. A
// site needing more languages should extend SUPPORTED_LANGS/ROW1_EXTRA/
// ROW2_EXTRA/ROW3_EXTRA/ROW2_OVERRIDES/ROW4_OVERRIDES rather than assume
// this already covers them.
//
// Also follows the focused field's own type: type="number"/"tel" fields
// get a compact numeric pad (renderNumeric()) instead of the full QWERTY
// layout, since those fields can only ever hold digits (plus -/. for
// number's negative/decimal values) -- see isNumericField().
(function () {
  "use strict";

  if (window.__kioskKeyboardInstalled) return;
  window.__kioskKeyboardInstalled = true;

  var SUPPORTED_LANGS = { da: true, de: true, nl: true, en: true };

  var ROW1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"];
  var ROW2 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"];
  var ROW3 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"];
  var ROW4 = ["z", "x", "c", "v", "b", "n", "m"];
  // QWERTZ: German swaps Y and Z relative to the QWERTY rows above.
  var ROW2_OVERRIDES = {
    de: ["q", "w", "e", "r", "t", "z", "u", "i", "o", "p"],
  };
  var ROW4_OVERRIDES = {
    de: ["y", "x", "c", "v", "b", "n", "m"],
  };
  // Per-language special characters, placed on the SAME row they actually
  // sit on on that language's real physical keyboard -- e.g. German ü is
  // an extension of row2 (next to p), ö/ä extend row3 (next to l), and ß
  // sits on the number row, NOT all four dumped onto one row regardless
  // of where they really belong (the previous, wrong approach: German's
  // four extra characters used to all get appended to row3 alone, making
  // it 13 keys wide and nowhere close to a real German keyboard's layout).
  var ROW1_EXTRA = {
    de: ["ß"],
  };
  var ROW2_EXTRA = {
    da: ["å"],
    de: ["ü"],
  };
  var ROW3_EXTRA = {
    da: ["æ", "ø"],
    de: ["ö", "ä"],
  };
  var SYMBOLS_ROW1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"];
  var SYMBOLS_ROW2 = ["@", "#", "$", "_", "&", "-", "+", "(", ")", "/"];
  var SYMBOLS_ROW3 = ["*", '"', "'", ":", ";", "!", "?"];
  var SYMBOLS_ROW4 = ["%", "€", "=", "[", "]", "{", "}"];

  function detectLanguage() {
    var lang = (document.documentElement.lang || "en").toLowerCase();
    var code = lang.split("-")[0];
    return Object.prototype.hasOwnProperty.call(SUPPORTED_LANGS, code) ? code : "en";
  }

  var NUMERIC_ROW1 = ["1", "2", "3"];
  var NUMERIC_ROW2 = ["4", "5", "6"];
  var NUMERIC_ROW3 = ["7", "8", "9"];
  var NUMERIC_ROW4 = ["-", "0", "."];

  // type="number"/"tel" fields can only ever hold digits (plus -/. for
  // number's negative/decimal values) -- showing the full QWERTY layout
  // for those is pure noise, so they get their own compact numeric pad
  // instead. Every other editable type keeps the regular layout.
  function isNumericField(el) {
    if (!el || el.tagName !== "INPUT") return false;
    var type = (el.type || "text").toLowerCase();
    return type === "number" || type === "tel";
  }

  var state = {
    target: null, // the input/textarea/contenteditable currently focused
    shift: false,
    symbols: false,
    numeric: false, // set on show() from isNumericField(target)
  };

  var root = document.createElement("div");
  root.id = "kiosk-keyboard-root";
  var style = document.createElement("style");
  // Key sizing: min-height 48px / max-width 64px. 48px (CSS px, i.e. after
  // devPixelsPerPx scaling -- see configuration.nix's own comment on that
  // value) matches the touch-target minimum from Google's Material Design
  // guidelines (also close to Apple HIG's 44pt and WCAG 2.1 SC 2.5.5's
  // 44x44px) -- small enough to fit a full row on this hardware's screen,
  // large enough for a finger tap to land reliably without hitting a
  // neighboring key. max-width caps how wide each key gets on top of that
  // minimum when a row has few keys (flex: 1 would otherwise stretch them
  // to fill the row's full width).
  style.textContent = [
    "#kiosk-keyboard-root {",
    "  position: fixed; left: 0; right: 0; bottom: 0;",
    "  z-index: 2147483647;", // max, to stay above whatever the page does
    "  display: none;",
    "  background: #22262b; color: #fff;",
    "  font-family: sans-serif;",
    "  padding: 6px env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);",
    "  box-shadow: 0 -2px 10px rgba(0,0,0,0.4);",
    "  user-select: none; -webkit-user-select: none;",
    "}",
    "#kiosk-keyboard-root.visible { display: block; }",
    "#kiosk-keyboard-root .kk-row { display: flex; justify-content: center; margin: 4px 0; }",
    "#kiosk-keyboard-root .kk-key {",
    "  flex: 1; max-width: 64px; margin: 0 3px;",
    "  min-height: 48px; display: flex; align-items: center; justify-content: center;",
    "  background: #3a3f47; border-radius: 6px; font-size: 20px;",
    "  border: 1px solid #4a505a;",
    "}",
    "#kiosk-keyboard-root .kk-key:active { background: #565d68; }",
    "#kiosk-keyboard-root .kk-key.kk-wide { flex: 3; max-width: none; }",
    "#kiosk-keyboard-root .kk-key.kk-space { flex: 8; max-width: none; }",
    "#kiosk-keyboard-root .kk-key.kk-active { background: #2f6fed; }",
  ].join("\n");
  document.documentElement.appendChild(style);

  function makeKey(label, opts) {
    opts = opts || {};
    var el = document.createElement("div");
    el.className = "kk-key" + (opts.wide ? " kk-wide" : "") + (opts.space ? " kk-space" : "");
    el.textContent = opts.display || label;
    el.dataset.key = label;
    return el;
  }

  function buildRow(keys) {
    var row = document.createElement("div");
    row.className = "kk-row";
    keys.forEach(function (k) {
      row.appendChild(makeKey(k));
    });
    return row;
  }

  function renderNumeric() {
    root.appendChild(buildRow(NUMERIC_ROW1));
    root.appendChild(buildRow(NUMERIC_ROW2));
    root.appendChild(buildRow(NUMERIC_ROW3));
    root.appendChild(buildRow(NUMERIC_ROW4));

    var row5 = document.createElement("div");
    row5.className = "kk-row";
    row5.appendChild(makeKey("__backspace__", { wide: true, display: "⌫" }));
    row5.appendChild(makeKey("__enter__", { wide: true, display: "⏎" }));
    row5.appendChild(makeKey("__hide__", { wide: true, display: "▼" }));
    root.appendChild(row5);
  }

  function render() {
    root.innerHTML = "";

    if (state.numeric) {
      renderNumeric();
      return;
    }

    var lang = detectLanguage();

    if (state.symbols) {
      root.appendChild(buildRow(SYMBOLS_ROW1));
      root.appendChild(buildRow(SYMBOLS_ROW2));
      root.appendChild(buildRow(SYMBOLS_ROW3));
      root.appendChild(buildRow(SYMBOLS_ROW4));
    } else {
      var caseFn = state.shift
        ? function (c) { return c.toUpperCase(); }
        : function (c) { return c; };
      var row1Keys = ROW1.concat(ROW1_EXTRA[lang] || []);
      var row2Keys = (ROW2_OVERRIDES[lang] || ROW2).concat(ROW2_EXTRA[lang] || []);
      var row3Keys = ROW3.concat(ROW3_EXTRA[lang] || []);
      var row4Keys = ROW4_OVERRIDES[lang] || ROW4;

      root.appendChild(buildRow(row1Keys));
      root.appendChild(buildRow(row2Keys.map(caseFn)));
      root.appendChild(buildRow(row3Keys.map(caseFn)));

      var row4 = document.createElement("div");
      row4.className = "kk-row";
      var shiftKey = makeKey("__shift__", { wide: true, display: "⇧" });
      if (state.shift) shiftKey.classList.add("kk-active");
      row4.appendChild(shiftKey);
      row4Keys.map(caseFn).forEach(function (k) { row4.appendChild(makeKey(k)); });
      row4.appendChild(makeKey("__backspace__", { wide: true, display: "⌫" }));
      root.appendChild(row4);
    }

    var row5 = document.createElement("div");
    row5.className = "kk-row";
    row5.appendChild(makeKey("__symbols__", { wide: true, display: state.symbols ? "ABC" : "123" }));
    row5.appendChild(makeKey("__space__", { space: true, display: " " }));
    row5.appendChild(makeKey("__enter__", { wide: true, display: "⏎" }));
    row5.appendChild(makeKey("__hide__", { wide: true, display: "▼" }));
    root.appendChild(row5);
  }

  // Insert `text` at the current cursor position of the focused field, and
  // fire the events that page JS (search widgets, form validation, React,
  // etc.) actually listens for.
  function insertText(text) {
    var el = state.target;
    if (!el) return;

    if (el.isContentEditable) {
      document.execCommand("insertText", false, text);
      return;
    }

    var start = el.selectionStart != null ? el.selectionStart : el.value.length;
    var end = el.selectionEnd != null ? el.selectionEnd : el.value.length;
    var before = el.value.slice(0, start);
    var after = el.value.slice(end);
    el.value = before + text + after;
    var caret = start + text.length;
    el.setSelectionRange(caret, caret);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function backspace() {
    var el = state.target;
    if (!el) return;

    if (el.isContentEditable) {
      document.execCommand("delete", false, null);
      return;
    }

    var start = el.selectionStart != null ? el.selectionStart : el.value.length;
    var end = el.selectionEnd != null ? el.selectionEnd : el.value.length;
    if (start === end) {
      if (start === 0) return;
      start -= 1;
    }
    el.value = el.value.slice(0, start) + el.value.slice(end);
    el.setSelectionRange(start, start);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function pressEnter() {
    var el = state.target;
    if (!el) return;
    // Real Enter keydown/keyup, not just a synthetic submit -- most search
    // boxes and form widgets listen for the key event itself.
    ["keydown", "keypress", "keyup"].forEach(function (type) {
      el.dispatchEvent(
        new KeyboardEvent(type, {
          key: "Enter",
          code: "Enter",
          keyCode: 13,
          which: 13,
          bubbles: true,
          cancelable: true,
        })
      );
    });

    // The dispatchEvent() calls above are synthetic (isTrusted: false),
    // and browsers deliberately don't run a form's IMPLICIT submission --
    // the behavior a real, trusted Enter keypress triggers -- for
    // untrusted events; that restriction exists specifically to stop
    // scripts from faking user submissions, which is exactly what this
    // function does on the user's behalf. For a plain <form> with no JS
    // of its own handling Enter (e.g. a default WordPress search widget),
    // the dispatchEvent calls above are a complete no-op and nothing else
    // happens -- confirmed live: Enter did nothing on this site's search
    // box. requestSubmit() explicitly performs that same submission
    // instead (falling back to the older submit() where unsupported),
    // which is why this runs in addition to, not instead of, the
    // synthetic key events above (which still matter for any widget whose
    // OWN JS listens for Enter directly, e.g. an AJAX-driven search box).
    var form = el.form || (el.closest && el.closest("form"));
    if (form) {
      if (typeof form.requestSubmit === "function") {
        form.requestSubmit();
      } else {
        form.submit();
      }
    }
  }

  function handleKey(key) {
    switch (key) {
      case "__shift__":
        state.shift = !state.shift;
        render();
        break;
      case "__symbols__":
        state.symbols = !state.symbols;
        render();
        break;
      case "__backspace__":
        backspace();
        break;
      case "__space__":
        insertText(" ");
        break;
      case "__enter__":
        pressEnter();
        break;
      case "__hide__":
        hide();
        break;
      default:
        insertText(key);
        if (state.shift) {
          state.shift = false;
          render();
        }
    }
  }

  root.addEventListener("mousedown", function (e) {
    // Without this, tapping a key blurs the input first (losing state.target
    // and the caret position) before the click/insert logic ever runs.
    e.preventDefault();
  });
  root.addEventListener("click", function (e) {
    var keyEl = e.target.closest(".kk-key");
    if (!keyEl) return;
    handleKey(keyEl.dataset.key);
  });

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

  function show(el) {
    state.target = el;
    state.shift = false;
    state.symbols = false;
    state.numeric = isNumericField(el);
    render();
    root.classList.add("visible");
    // best-effort: keep the field visible above the keyboard
    setTimeout(function () {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
    }, 50);
  }

  function hide() {
    state.target = null;
    root.classList.remove("visible");
  }

  document.addEventListener(
    "focusin",
    function (e) {
      if (isEditable(e.target)) show(e.target);
    },
    true
  );
  document.addEventListener(
    "focusout",
    function (e) {
      // If focus is moving to the keyboard itself, mousedown's
      // preventDefault already stopped that; anywhere else, hide.
      setTimeout(function () {
        if (!isEditable(document.activeElement)) hide();
      }, 0);
    },
    true
  );

  document.documentElement.appendChild(root);
})();

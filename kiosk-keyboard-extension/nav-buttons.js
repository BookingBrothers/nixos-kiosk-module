// Small floating nav buttons for kiosks with no browser chrome at all (no
// back/home button, no swipe-back gesture support in cage/Wayland):
//   - Back (history.back()) -- for a kiosk with subpages to navigate back
//     out of. Gated by window.__KIOSK_ENABLE_BACK_BUTTON__.
//   - Home (navigates to window.__KIOSK_HOME_URL__, the site's own
//     kiosk_url) -- a one-tap reset back to the intended page, for when a
//     visitor has wandered several pages deep. Gated by
//     window.__KIOSK_ENABLE_HOME_BUTTON__.
// Both flags (and __KIOSK_HOME_URL__) are set by config.js, from
// configuration.nix's `enableBackButton`/`enableHomeButton`/`kiosk_url` --
// independent toggles, a host can enable either, both, or neither.
// Top-left corner, not bottom -- kept out of the way of page content that
// tends to run to the bottom (e.g. this site's own on-screen keyboard,
// when it's showing).
(function () {
  "use strict";

  var showBack = !!window.__KIOSK_ENABLE_BACK_BUTTON__;
  var showHome = !!window.__KIOSK_ENABLE_HOME_BUTTON__;
  if (!showBack && !showHome) return;

  var bar = document.createElement("div");
  bar.style.cssText = [
    "position: fixed",
    "left: 14px",
    "top: 14px",
    "z-index: 2147483647",
    "display: flex",
    "gap: 10px",
  ].join(";");

  function makeButton(label, onClick) {
    var btn = document.createElement("div");
    btn.textContent = label;
    btn.setAttribute("role", "button");
    // 54px, a bit above the 48px touch-target minimum content.js's
    // keyboard keys and context-menu.js's buttons use (see their own
    // comments on that baseline) -- deliberately larger here since these
    // are standalone persistent controls a visitor reaches for without
    // other keys around them to miss, and mis-tapping one (unlike a wrong
    // keyboard letter) immediately navigates away from wherever they were.
    btn.style.cssText = [
      "width: 54px",
      "height: 54px",
      "border-radius: 50%",
      "background: rgba(34,38,43,0.85)",
      "color: #fff",
      "font-family: sans-serif",
      "font-size: 24px",
      "line-height: 1",
      "display: flex",
      "align-items: center",
      "justify-content: center",
      "user-select: none",
      "box-shadow: 0 2px 8px rgba(0,0,0,0.4)",
      "transition: opacity 0.15s ease",
    ].join(";");
    // Without this, tapping the button blurs whatever's focused first --
    // same reasoning as content.js's own keyboard root and context-menu.js.
    btn.addEventListener("mousedown", function (e) {
      e.preventDefault();
    });
    btn.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      onClick();
    });
    return btn;
  }

  if (showBack) {
    var backBtn = makeButton("←", function () {
      window.history.back();
    });
    backBtn.setAttribute("aria-label", "Back");

    // history.length is a reasonable proxy for "is there anywhere to go
    // back to" specifically because firefox-kiosk.sh wipes the profile
    // fresh on every cage-tty1 start -- the kiosk always launches straight
    // to kiosk_url as entry 1, so length > 1 only happens from a visitor's
    // own subsequent same-tab navigation, not leftover history from a
    // previous session.
    function refreshBack() {
      var canGoBack = window.history.length > 1;
      backBtn.style.opacity = canGoBack ? "1" : "0.35";
      backBtn.style.pointerEvents = canGoBack ? "auto" : "none";
    }
    window.addEventListener("popstate", refreshBack);
    refreshBack();

    bar.appendChild(backBtn);
  }

  if (showHome && window.__KIOSK_HOME_URL__) {
    var homeBtn = makeButton("⌂", function () {
      location.href = window.__KIOSK_HOME_URL__;
    });
    homeBtn.setAttribute("aria-label", "Home");
    bar.appendChild(homeBtn);
  }

  document.documentElement.appendChild(bar);
})();

// Two related guards against ending up on a hostname not in
// window.__KIOSK_ALLOWED_HOSTS__ (set by config.js, from
// services.kiosk-mode.navigation.allowedHosts). Both are a no-op if
// that's unset/null:
//
//   1. Blocks the click on a link to a disallowed host before the
//      navigation happens at all.
//   2. Redirects back to __KIOSK_HOME_URL__ if the top-level document
//      has ALREADY ended up on a disallowed host by any means #1 can't
//      catch -- a script-driven `location.href` change, a form POST, a
//      meta-refresh, or a server-side redirect from an otherwise-
//      allowed page.
//
// This exists because the site's own content can legitimately link
// off-site (e.g. an embedded YouTube video's own "Watch on YouTube"
// button) -- clicking through on any of those is a real, direct
// kiosk-escape route that needs no keyboard trick at all, unlike Ctrl+L
// (see ../default.nix's kioskMode comment for that separate, still-open
// issue). Only the embedded PLAYER itself (an iframe on a different
// origin, loaded by the page as intended content) is left alone -- this
// only intercepts a visitor actually clicking a link to leave the site,
// not third-party content the site owner chose to embed.
//
// Loaded via its own all_frames:true content_scripts entry in
// manifest.json (config.js alongside it, so each frame's isolated world
// gets its own __KIOSK_ALLOWED_HOSTS__ -- that's per-frame, not shared
// with the top document) -- confirmed live that "Watch on YouTube"-style
// overlay links on an embed are real <a target="_top"> elements inside
// the IFRAME's own document, invisible to a top-frame-only content script
// (manifest.json's other, all_frames:false entry) no matter what it
// listens for on the parent page.
//
// Deliberately only intercepts link CLICKS, not window.open() calls made
// by page JS: content scripts run in an isolated JS world in Firefox, so
// monkey-patching window.open from here would not affect the page's own
// reference to it. DOM click events, unlike direct object access, do
// cross that world boundary, which is why this approach works reliably
// and a JS-object-patching one would not.
(function () {
  "use strict";

  var allowedHosts = window.__KIOSK_ALLOWED_HOSTS__;
  if (!allowedHosts || !allowedHosts.length) return;

  function isAllowed(url) {
    var u;
    try {
      u = new URL(url, location.href);
    } catch (e) {
      return true; // unparseable -- not a real navigation, leave it alone
    }
    // javascript: is page-internal (a common pattern for JS-driven button
    // links, e.g. "javascript:void(0)") -- not a navigation at all, and
    // blocking it would break legitimate on-page interactivity.
    if (u.protocol === "javascript:") return true;
    // Everything else non-http(s) -- mailto:, tel:, sms:, custom app
    // URI schemes -- hands off to the OS rather than navigating within
    // Firefox. Confirmed live: a mailto: link produced a native "Choose
    // an application to open the mailto link" dialog offering Gmail (a
    // full web app) or an arbitrary "Choose other Application" picker --
    // as real a kiosk-escape route as a blocked http(s) link, just via a
    // different mechanism. Block unconditionally rather than trying to
    // enumerate which schemes are "safe".
    if (u.protocol !== "http:" && u.protocol !== "https:") return false;
    return allowedHosts.some(function (host) {
      return u.hostname === host || u.hostname.endsWith("." + host);
    });
  }

  document.addEventListener(
    "click",
    function (e) {
      var link = e.target.closest && e.target.closest("a[href]");
      if (!link) return;
      if (!isAllowed(link.href)) {
        e.preventDefault();
        e.stopPropagation();
      }
    },
    true
  );

  // Catches everything the click listener above can't: a script-driven
  // `location.href = ...` (isolated-world content scripts can't stop
  // that from here either, same reasoning as the window.open() comment
  // above), a form POST, a meta-refresh, or a page on an allowed host
  // that itself server-side redirects somewhere not allowed. Runs once
  // per top-level navigation (a fresh navigation re-injects this
  // content script from scratch, so there's no need for this to be a
  // recurring poll) -- top frame only, since window.top === window.self
  // is false inside a legitimately embedded iframe (e.g. a video
  // player), whose own location being on a different host is expected,
  // not a kiosk-escape.
  //
  // isAllowed(homeUrl) is a fail-safe, not an expected case: it's only
  // false if the operator's own allowedHosts doesn't cover their own
  // url's host (needed separately anyway, for ordinary links TO it to
  // work) -- without this guard, that specific misconfiguration would
  // make the redirect target of this very check fail its own check,
  // reloading forever instead of just not redirecting.
  var homeUrl = window.__KIOSK_HOME_URL__;
  if (
    window.top === window.self &&
    homeUrl &&
    location.href !== homeUrl &&
    !isAllowed(location.href) &&
    isAllowed(homeUrl)
  ) {
    location.replace(homeUrl);
  }
})();

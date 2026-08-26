// Blocks top-level navigation (link clicks) to any hostname not in
// window.__KIOSK_ALLOWED_HOSTS__ (set by config.js, from configuration.nix's
// `restrictNavigationToHosts`). A no-op if that's unset/null.
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
})();

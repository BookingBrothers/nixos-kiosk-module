#!/usr/bin/env bash
# ExecStartPre for cage-tty1.service (see ../default.nix): (re)writes a
# fresh Firefox profile every time the service starts, so the kiosk never
# accumulates history/cache/session state across restarts or reboots.
#
# DEV_PIXELS_PER_PX and KIOSK_HOME come in via ../default.nix's
# services.cage.environment -- see that file's `devPixelsPerPx` binding for
# why the right DEV_PIXELS_PER_PX value depends on screenRotation (it
# changes the effective CSS viewport width, and rotation changes which
# physical dimension is "width"). KIOSK_HOME is just /home/${username};
# passed in rather than hardcoded so this file works for any consumer's
# `username`, not only "kiosk".
#
# browser.privatebrowsing.autostart below is driven by KIOSK_PRIVATE_BROWSING
# (services.kiosk-mode.privateBrowsing), not tied to `mode` -- when on, it
# forces permanent private browsing on the whole profile regardless of
# which CLI flag (--private-window vs --kiosk) actually launched it. This
# is why the kiosk-keyboard extension's `private_browsing = true` policy
# setting (../default.nix) is required whenever this is on, for BOTH
# `mode` values, not just "custom".
#
# CORRECTNESS-CRITICAL, confirmed via an isolated local A/B repro (same
# Firefox build, same exact Permissions.Camera/Microphone policy JSON,
# same getUserMedia() call): private browsing being on silently breaks
# services.kiosk-mode.permissions.<type>'s `allow` list for a real
# getUserMedia()-based site -- Firefox's enterprise-policy Allow
# exception is implemented through the same permission-manager mechanism
# as a real user's remembered site permission, which isn't honored
# inside a permanently-private session (BlockNewRequests, a plain global
# pref, still works fine either way -- it's specifically the per-origin
# Allow exception that doesn't apply). A host that needs `permissions.*`
# to actually work for such a site needs this off.
set -eu
: "${KIOSK_HOME:?}"
: "${KIOSK_PRIVATE_BROWSING:?}"

rm -rf "$KIOSK_HOME/.mozilla" "$KIOSK_HOME/.config/mozilla" "$KIOSK_HOME/.cache/mozilla" /tmp/firefox-kiosk-profile

PROFILE_DIR="/tmp/firefox-kiosk-profile"
mkdir -p "$PROFILE_DIR/chrome"

PRIVATE_BROWSING_PREF=""
if [ "$KIOSK_PRIVATE_BROWSING" = "true" ]; then
  PRIVATE_BROWSING_PREF='user_pref("browser.privatebrowsing.autostart", true);'
fi

cat > "$PROFILE_DIR/user.js" << EOF
user_pref("layout.css.devPixelsPerPx", "$DEV_PIXELS_PER_PX");
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("browser.fullscreen.autohide", true);
user_pref("full-screen-api.warning.timeout", 0);
user_pref("full-screen-api.transition-duration.enter", "0 0");
user_pref("full-screen-api.transition-duration.leave", "0 0");
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
$PRIVATE_BROWSING_PREF
user_pref("signon.rememberSignons", false);
EOF

# See ../default.nix's `storageSyncSeedDb` comment: pre-seeds any
# extension's browser.storage.sync data (e.g. Consent-O-Matic's own
# "already seen the options page once" flag) so a freshly-wiped profile
# doesn't lose it -- and doesn't re-trigger whatever it gates -- on every
# single kiosk restart. Only set when at least one configured extension
# sets `storageSyncSeed`.
if [ -n "${KIOSK_STORAGE_SYNC_SEED_DB:-}" ]; then
  cp "$KIOSK_STORAGE_SYNC_SEED_DB" "$PROFILE_DIR/storage-sync-v2.sqlite"
  # The source is a read-only Nix store path; Firefox needs to write to
  # this file (WAL journal, any later change to synced storage), not just
  # read it.
  chmod 644 "$PROFILE_DIR/storage-sync-v2.sqlite"
fi

cat > "$PROFILE_DIR/chrome/userChrome.css" << 'EOF'
#TabsToolbar { visibility: collapse !important; }
#nav-bar { visibility: collapse !important; }
#PersonalToolbar { visibility: collapse !important; }
#sidebar-header, #sidebar-box { visibility: collapse !important; }
#titlebar { visibility: collapse !important; }
EOF

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
# browser.privatebrowsing.autostart=true below is set UNCONDITIONALLY, not
# just for kioskMode="custom" -- it forces permanent private browsing on
# the whole profile regardless of which CLI flag (--private-window vs
# --kiosk) actually launched it. This is why the kiosk-keyboard extension's
# `private_browsing = true` policy setting (../default.nix) is required
# for BOTH kioskMode values, not just "custom".
set -eu
: "${KIOSK_HOME:?}"

rm -rf "$KIOSK_HOME/.mozilla" "$KIOSK_HOME/.config/mozilla" "$KIOSK_HOME/.cache/mozilla" /tmp/firefox-kiosk-profile

PROFILE_DIR="/tmp/firefox-kiosk-profile"
mkdir -p "$PROFILE_DIR/chrome"

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
user_pref("browser.privatebrowsing.autostart", true);
user_pref("signon.rememberSignons", false);
EOF

# See ../default.nix's `consentOMaticSyncSeedDb` comment: pre-seeds
# Consent-O-Matic's own "already seen the options page once" flag so a
# freshly-wiped profile doesn't reopen it on every single kiosk restart.
# Only set when enableConsentOMatic is on.
if [ -n "${CONSENT_O_MATIC_SYNC_SEED_DB:-}" ]; then
  cp "$CONSENT_O_MATIC_SYNC_SEED_DB" "$PROFILE_DIR/storage-sync-v2.sqlite"
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

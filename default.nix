########################################################################
# services.kiosk-mode: a single-purpose touchscreen/display kiosk --
# cage (a Wayland compositor for exactly one fullscreen client) running
# Firefox pinned to one URL, with the browser profile wiped and rebuilt
# from scratch on every restart so the kiosk never accumulates
# history/cache/session state across restarts or reboots.
#
# Plain NixOS module, importable with or without flakes:
#
#   # classic (no flakes): channels, niv, a vendored checkout, etc.
#   imports = [ /path/to/nixos-kiosk-mode ];
#
#   # flakes
#   imports = [ inputs.nixos-kiosk-mode.nixosModules.default ];
#
# Both forms load this exact file -- flake.nix in this repo is a thin
# wrapper around it, not a second copy. See ./flake.nix and ./README.md.
########################################################################
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kiosk-mode;

  enableNavExtension =
    cfg.navigation.onScreenKeyboard.enable
    || cfg.navigation.backButton.enable
    || cfg.navigation.homeButton.enable
    || cfg.navigation.allowedHosts != null;

  # The one generated file in the on-screen-keyboard/nav extension: pure
  # data assignments (no control flow, nothing script-like) handing this
  # host's resolved config to the otherwise fully static nav-buttons.js/
  # nav-guard.js content scripts.
  kioskExtensionConfig = pkgs.writeText "config.js" ''
    window.__KIOSK_ENABLE_BACK_BUTTON__ = ${lib.boolToString cfg.navigation.backButton.enable};
    window.__KIOSK_ENABLE_HOME_BUTTON__ = ${lib.boolToString cfg.navigation.homeButton.enable};
    window.__KIOSK_HOME_URL__ = ${builtins.toJSON cfg.url};
    window.__KIOSK_ALLOWED_HOSTS__ = ${
      if cfg.navigation.allowedHosts != null then builtins.toJSON cfg.navigation.allowedHosts else "null"
    };
  '';

  kioskKeyboardXpi = pkgs.runCommand "kiosk-keyboard.xpi" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir build
    cp ${./kiosk-keyboard-extension}/manifest.json build/manifest.json
    cp ${./kiosk-keyboard-extension}/content.js build/content.js
    cp ${./kiosk-keyboard-extension}/context-menu.js build/context-menu.js
    cp ${./kiosk-keyboard-extension}/nav-buttons.js build/nav-buttons.js
    cp ${./kiosk-keyboard-extension}/nav-guard.js build/nav-guard.js
    cp ${kioskExtensionConfig} build/config.js
    cd build
    zip -r -X $out manifest.json content.js context-menu.js nav-buttons.js nav-guard.js config.js
  '';

  # Consent-O-Matic (auto-answers GDPR cookie-consent dialogs) opens its
  # own options.html tab once on every FRESH profile -- its background
  # script gates this on a browser.storage.sync flag that defaults to
  # true and flips itself to false right after. On a normal install
  # that's a harmless one-time thing, but this module wipes and recreates
  # the whole profile on every single restart, so without pre-seeding
  # that flag it re-triggers EVERY restart, stealing the display from
  # `cfg.url`.
  #
  # Schema/table names/data shape here are copied verbatim from a real
  # Firefox profile's storage-sync-v2.sqlite after letting the extension
  # flip the flag itself once and inspecting the result -- Firefox's
  # on-disk format for this API isn't documented anywhere reliable.
  #
  # CORRECTNESS-CRITICAL: `PRAGMA user_version = 2;` below. Firefox's own
  # storage-sync engine stamps every database it creates with this
  # (schema version, not app version); a bare `sqlite3` CREATE leaves it
  # at the SQLite default of 0. Confirmed live this isn't cosmetic:
  # shipping this file without it silently broke Consent-O-Matic's
  # ENTIRE background script (not just the flag read) -- its per-
  # extension storage directory never got created at all, vs. a matching
  # real-Firefox-created db (user_version=2) where it initialized
  # normally. Don't drop this pragma without re-verifying against a
  # fresh Firefox-created db first; a wrong version here fails exactly
  # this silently again.
  consentOMaticSyncSeedDb = pkgs.runCommand "consent-o-matic-storage-sync-seed.sqlite" {
    nativeBuildInputs = [ pkgs.sqlite ];
  } ''
    sqlite3 "$out" <<'SQL'
    PRAGMA user_version = 2;
    CREATE TABLE meta (
        key TEXT PRIMARY KEY,
        value NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE storage_sync_data (
        ext_id TEXT NOT NULL PRIMARY KEY,
        data TEXT,
        sync_change_counter INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE storage_sync_mirror (
        guid TEXT NOT NULL PRIMARY KEY,
        ext_id TEXT UNIQUE,
        data TEXT,
        CHECK((ext_id IS NULL AND data IS NULL) OR (ext_id IS NOT NULL AND data IS NOT NULL))
    );
    INSERT INTO storage_sync_data (ext_id, data, sync_change_counter)
      VALUES ('gdpr@cavi.au.dk', '{"debugFlags":{"autoOpenOptionsTab":false}}', 1);
    SQL
  '';
in
{
  options.services.kiosk-mode = {
    enable = lib.mkEnableOption "a single-purpose touchscreen/display kiosk (cage + Firefox pinned to one URL)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "kiosk";
      description = "Local user cage/Firefox run as. Created by this module.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      example = "https://example.com/";
      description = "The URL to show, and what the kiosk resets back to on restart/idle-timeout.";
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "custom"
        "builtin"
      ];
      default = "custom";
      description = ''
        "custom": launches Firefox with `--private-window`, browser chrome
        hidden via userChrome.css (scripts/firefox-kiosk.sh).
        "builtin": launches with Firefox's own `--kiosk` flag instead.

        Neither value blocks Ctrl+L/T/N/S/U from reaching Firefox's own
        keybindings -- a known open gap in both modes, not yet fixed.
        Permanent private browsing (browser.privatebrowsing.autostart)
        is forced unconditionally either way, regardless of this setting.
      '';
    };

    screenRotation = lib.mkOption {
      type = lib.types.enum [
        "normal"
        "left"
        "right"
        "inverted"
      ];
      default = "normal";
      description = "Applied via wlr-randr (xrandr-style naming) against the live compositor.";
    };

    devPixelsPerPx = lib.mkOption {
      type = lib.types.str;
      default = "1";
      example = "2.5";
      description = ''
        layout.css.devPixelsPerPx: makes touch targets bigger by shrinking
        the *effective CSS viewport* (physical px / this value = CSS px).
        The right value is rotation- and site-dependent -- this module
        doesn't try to compute one, it's a plain passthrough.
      '';
    };

    idleTimeoutMinutes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Minutes of no touch activity before the kiosk restarts itself back
        to `url` (a systemd timer + a raw-input-reading watchdog --
        deliberately NOT a JS page timer, since a hung tab or a page that
        stops-propagation on input events could silently disable one of
        those). 0 disables idle-reset entirely. Requires `touch` to be
        set -- nothing to watch for activity otherwise.

        Repeats for as long as the kiosk stays genuinely idle, not just
        once: the reset re-arms its own timer right after firing, so an
        untouched kiosk keeps resetting every `idleTimeoutMinutes`
        indefinitely. A real touch still extends the deadline immediately
        either way.
      '';
    };

    touch = lib.mkOption {
      default = null;
      description = ''
        Touchscreen calibration and a stable /dev/input/kiosk-touch udev
        symlink. null (the default) means no touchscreen -- e.g. a fixed
        display panel with no touch input at all.

        Rotating the *output* (`screenRotation`) doesn't rotate *touch
        input* -- most digitizers report raw physical coordinates
        regardless of how the display is rotated, so libinput needs an
        explicit calibration matrix or touches land offset from what's on
        screen. cage has no per-compositor config for this, so it's done
        at the udev/libinput layer instead, which is compositor-
        independent anyway. These values are physically measured against
        one specific piece of hardware -- there's no way to derive them
        generically, so this module takes the already-resolved matrix
        string rather than trying to compute one.
      '';
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            vendorId = lib.mkOption {
              type = lib.types.str;
              example = "0eef";
              description = "Matched against ATTRS{idVendor} (services.udev.extraRules).";
            };
            productId = lib.mkOption {
              type = lib.types.str;
              example = "c002";
              description = "Matched against ATTRS{idProduct} (services.udev.extraRules).";
            };
            calibrationMatrix = lib.mkOption {
              type = lib.types.str;
              example = "1 0 0 0 1 0";
              description = ''
                The final, already-resolved-for-the-current-rotation
                LIBINPUT_CALIBRATION_MATRIX string (same X.Org Coordinate
                Transformation Matrix convention libinput uses).
              '';
            };
          };
        }
      );
    };

    navigation = {
      onScreenKeyboard.enable = lib.mkEnableOption ''
        a touch on-screen keyboard, force-installed as a browser extension
        (layout follows the page's declared language, falling back to
        plain QWERTY for anything not explicitly covered -- see
        kiosk-keyboard-extension/content.js). Off by default: most
        dashboards (e.g. a read-only display) have nothing to type into
      '';

      backButton.enable = lib.mkEnableOption ''
        a small floating back button (history.back()), top-left corner --
        independent of onScreenKeyboard, since a kiosk can have subpages
        to navigate back out of without needing text input at all
      '';

      homeButton.enable = lib.mkEnableOption ''
        a small floating home button (navigates to `url`), alongside the
        back button in the same top-left corner
      '';

      allowedHosts = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [
          "example.com"
          "example.org"
        ];
        description = ''
          A list of hostnames, or null to disable. When set, blocks
          clicking any link to a hostname NOT in the list (or a subdomain
          of one) -- a direct kiosk-escape route needing no keyboard
          trick at all (e.g. an embedded video's own "watch on the
          original site" button, or a mailto: link opening a native
          "choose an application" dialog). Doesn't touch legitimately
          embedded third-party content (iframes) -- only intercepts a
          visitor actually clicking through to leave the site. A list
          rather than one hostname since a site can legitimately span
          more than one domain (e.g. a short-link domain alongside the
          main one, or a companion platform it links out to).
        '';
      };
    };

    audio.enable = lib.mkEnableOption "PipeWire audio for the kiosk session (off by default -- only worth it if the site actually plays sound and the hardware has a real output route)";

    allowVtSwitch = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        cage's `-s` flag (allow Ctrl+Alt+Fn VT switching, which cage
        disables by default). Off by default. Turning this on re-enables
        console access at the physical device straight to a getty login
        prompt on another VT -- consider what accounts exist and what
        they can do before enabling this on a public-facing kiosk.
      '';
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "video" ];
      description = "Extra groups for the kiosk user beyond the default none -- e.g. `video` on a host with a USB webcam Firefox needs to open.";
    };

    extensions = {
      uBlockOrigin.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Force-install uBlock Origin. On by default: worth having on any
          kiosk rendering real third-party web content. A real, AMO-
          hosted, normally-signed extension -- installed straight from
          addons.mozilla.org, no signature-bypass needed.
          `installation_mode = "normal_installed"` rather than
          "force_installed": it ships pre-installed and enabled, but
          stays a regular extension anyone with browser UI access
          (about:addons) can disable or remove -- not policy-locked on.
        '';
      };

      consentOMatic.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Force-install Consent-O-Matic (auto-answers GDPR cookie-consent
          dialogs -- built by Aarhus University's CAVI). On by default
          for the same reason as uBlock Origin: a kiosk nobody is
          standing at to click "Accept" through a modal cookie banner
          needs it handled automatically.
        '';
      };

      autoscrollShorts.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Force-install "Autoscroll Shorts" (auto-advances to the next
          YouTube Short when the current one ends). Off by default --
          unlike uBlock/Consent-O-Matic, this is only useful on a kiosk
          that actually shows YouTube Shorts. Picked over several similar
          extensions specifically because it has no storage/settings/
          toggle at all (verified by reading its full content script) --
          it just always runs, so there's nothing to fight against this
          module's wipe-every-restart profile, unlike other Shorts auto-
          scrollers that either default off or reopen their own install
          tab every restart via a storage.local flag (much harder to
          pre-seed than storage.sync -- see consentOMaticSyncSeedDb's own
          comment for why storage.sync is already the harder case).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.idleTimeoutMinutes == 0 || cfg.touch != null;
        message = "services.kiosk-mode.idleTimeoutMinutes > 0 requires services.kiosk-mode.touch to be set -- nothing to watch for activity otherwise";
      }
    ];

    # Prevents a real, repeatedly-hit race rather than papering over it:
    # cage always claims tty1 (TTYPath in nixpkgs' cage module), and
    # whenever cage-tty1.service is briefly stopped (e.g. mid
    # nixos-rebuild switch, or an idle-reset restart), systemd-logind can
    # auto-spawn getty@tty1.service on the now-free VT before cage-tty1
    # gets back to it. `Restart=always` on cage-tty1 does NOT recover from
    # this -- that only fires on the process exiting, not on losing a
    # race for the tty, so the service was observed sitting "failed"
    # indefinitely with getty holding tty1 until someone manually stopped
    # getty and restarted cage-tty1. Masking getty@tty1 removes the race
    # entirely -- there is no unit left to win it -- rather than trying
    # to out-time it. VT2-6 keep their own getty units untouched, so
    # console access via other VTs (when allowVtSwitch is on) is
    # unaffected.
    systemd.services."getty@tty1".enable = false;

    services.udev.extraRules = lib.mkIf (cfg.touch != null) ''
      SUBSYSTEM=="input", ATTRS{idVendor}=="${cfg.touch.vendorId}", ATTRS{idProduct}=="${cfg.touch.productId}", ENV{LIBINPUT_CALIBRATION_MATRIX}="${cfg.touch.calibrationMatrix}"
      SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="${cfg.touch.vendorId}", ATTRS{idProduct}=="${cfg.touch.productId}", SYMLINK+="input/kiosk-touch"
    '';

    services.pulseaudio.enable = lib.mkIf cfg.audio.enable false;
    security.rtkit.enable = lib.mkIf cfg.audio.enable true;
    services.pipewire = lib.mkIf cfg.audio.enable {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    programs.firefox = {
      enable = true;
      # devedition specifically: requireSigning=false, needed to install
      # the unsigned on-screen-keyboard/nav extension at all. Plain
      # firefox hard-enforces AMO signature checks with no override --
      # only worth the non-default package when actually needed.
      package = if enableNavExtension then pkgs.firefox-devedition else pkgs.firefox;
      policies = lib.mkMerge [
        {
          DisableAppUpdate = true;
          DisplayBookmarksToolbar = "never";
          DisplayMenuBar = "never";
          # Closes another kiosk-escape route alongside context-menu.js
          # (kiosk-keyboard-extension/, only installed when
          # enableNavExtension is true): removes any "Inspect"/DevTools
          # entry that would otherwise still appear on the editable-field
          # context menu that script deliberately leaves alone, and
          # blocks the F12/Ctrl+Shift+I shortcuts directly -- neither of
          # which a content script can touch on its own. Applied
          # unconditionally: worth having on any kiosk regardless.
          DisableDeveloperTools = true;
          # Firefox's built-in AI Chatbot sidebar (visible as "Ask an AI
          # Chatbot" in the native context menu, keyboard shortcut "Z")
          # -- unrelated to a kiosk's own purpose and another surface for
          # a visitor to reach the open internet from. Locked off
          # unconditionally, same reasoning as DisableDeveloperTools
          # above.
          Preferences."browser.ml.chat.enabled" = {
            Value = false;
            Status = "locked";
          };
        }
        (lib.mkIf enableNavExtension {
          Preferences = {
            "xpinstall.signatures.required" = {
              Value = false;
              Status = "locked";
            };
          };
          Extensions.Install = [ "file://${kioskKeyboardXpi}" ];
          ExtensionSettings."kiosk-keyboard@dashboard.local" = {
            installation_mode = "allowed";
            # Required for BOTH `mode` values, not just "custom" --
            # scripts/firefox-kiosk.sh sets
            # browser.privatebrowsing.autostart=true unconditionally, and
            # Firefox disables extensions in private-browsing windows by
            # default.
            private_browsing = true;
          };
        })
        (lib.mkIf cfg.extensions.uBlockOrigin.enable {
          ExtensionSettings."uBlock0@raymondhill.net" = {
            # No install_url: as of Firefox 153, it's optional for
            # AMO-hosted extensions -- omitted, Firefox resolves and
            # installs the latest version straight from AMO by extension
            # ID instead. Confirmed live that the explicit install_url
            # form (addons.mozilla.org/.../latest.xpi) silently failed to
            # trigger an install at all on a current Firefox devedition
            # build, despite working network access to AMO -- use the
            # ID-only form current Firefox versions expect.
            installation_mode = "normal_installed";
            # Same private-browsing gotcha as kiosk-keyboard above --
            # without this, uBlock installs but never actually runs.
            private_browsing = true;
          };
        })
        (lib.mkIf cfg.extensions.consentOMatic.enable {
          # ID per rycee/nur-expressions' generated-firefox-addons.nix --
          # not guessed, since AMO's own listing page doesn't surface the
          # extension ID directly.
          ExtensionSettings."gdpr@cavi.au.dk" = {
            installation_mode = "normal_installed";
            private_browsing = true;
          };
        })
        (lib.mkIf cfg.extensions.autoscrollShorts.enable {
          # ID from the actual published xpi's manifest.json (downloaded
          # and inspected directly from AMO), not guessed. No install_url,
          # same Firefox-153+ AMO-by-ID reasoning as uBlock above.
          ExtensionSettings."{96d7f719-11f8-427d-898f-51b4a3803952}" = {
            installation_mode = "normal_installed";
            # Still required even though this extension has no storage/
            # settings of its own to be blocked by -- private_browsing
            # controls whether its CONTENT SCRIPT is allowed to run in a
            # private window at all, independent of what the extension
            # does or doesn't persist.
            private_browsing = true;
          };
        })
      ];
    };

    environment.systemPackages = [ pkgs.wlr-randr ]; # used by scripts/screen-rotation.sh

    services.cage = {
      enable = true;
      user = cfg.user;
      extraArguments = lib.optional cfg.allowVtSwitch "-s";
      # A wrapper, not a bare firefox invocation -- backgrounds the
      # rotation wait-and-apply before exec'ing firefox, both inside the
      # ONE process cage launches as its client (a separate ExecStartPost
      # for the rotation step hits a PAM session-ordering error instead).
      program = pkgs.writeShellScript "kiosk-launch" (builtins.readFile ./scripts/kiosk-launch.sh);
      environment = {
        # See scripts/firefox-kiosk.sh's header for why this is passed in
        # rather than hardcoded there.
        KIOSK_HOME = "/home/${cfg.user}";
        DEV_PIXELS_PER_PX = cfg.devPixelsPerPx;
        SCREEN_ROTATION = cfg.screenRotation;
        SCREEN_ROTATION_SCRIPT = "${pkgs.writeShellScript "screen-rotation" (builtins.readFile ./scripts/screen-rotation.sh)}";
        FIREFOX_BIN = lib.getExe config.programs.firefox.finalPackage;
        KIOSK_MODE_FLAG = if cfg.mode == "builtin" then "--kiosk" else "--private-window";
        KIOSK_URL = lib.replaceString "%" "%%" cfg.url;
      }
      # Unused by kiosk-launch.sh -- only here so cage-tty1.service's own
      # unit content changes whenever the extension's xpi changes, so
      # restartIfChanged (below) actually restarts cage-tty1 on THAT
      # deploy instead of needing a separate manual restart afterward.
      // lib.optionalAttrs enableNavExtension {
        KIOSK_EXTENSION_XPI = "${kioskKeyboardXpi}";
      }
      # Same reasoning as KIOSK_EXTENSION_XPI above.
      // lib.optionalAttrs cfg.extensions.consentOMatic.enable {
        CONSENT_O_MATIC_SYNC_SEED_DB = "${consentOMaticSyncSeedDb}";
      };
    };
    systemd.services."cage-tty1" = {
      # nixpkgs' cage module sets false; we do want cage restarted on switch
      restartIfChanged = lib.mkForce true;
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "firefox-kiosk-setup" (builtins.readFile ./scripts/firefox-kiosk.sh);
        Restart = "always";
        RestartSec = "5s";
      };
    };

    # Idle-timeout auto-reset. Three units, systemd-timer-native rather
    # than a hand-rolled polling loop.
    systemd.timers."kiosk-idle-reset" = lib.mkIf (cfg.idleTimeoutMinutes > 0) {
      description = "Countdown to a kiosk restart after a period of touch inactivity";
      timerConfig.OnActiveSec = "${toString cfg.idleTimeoutMinutes}min";
      # scripts/idle-watchdog.sh calls `systemctl restart` on this unit
      # once per RAW touch input_event -- a touchscreen emits dozens of
      # those per second during any real interaction (scrubbing a
      # video's progress bar, scrolling), which blows straight through
      # systemd's default restart rate limit (5/10s). Confirmed live:
      # the timer hit "start-limit-hit" and failed outright, which then
      # crashed kiosk-idle-watchdog.service itself (its `systemctl
      # restart` returning nonzero under `set -eu`) into a genuine,
      # repeated crash loop. Restarting this timer on every touch is
      # normal, expected, and cheap, not the failure storm the rate
      # limit exists to protect against, so it's uncapped entirely
      # rather than just raised.
      unitConfig.StartLimitIntervalSec = 0;
    };
    systemd.services."kiosk-idle-reset" = lib.mkIf (cfg.idleTimeoutMinutes > 0) {
      description = "Restart the kiosk (fired by kiosk-idle-reset.timer expiring)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          "${pkgs.systemd}/bin/systemctl restart cage-tty1.service"
          "${pkgs.systemd}/bin/systemctl restart kiosk-idle-reset.timer"
        ];
      };
    };
    systemd.services."kiosk-idle-watchdog" = lib.mkIf (cfg.idleTimeoutMinutes > 0) {
      description = "Re-arm kiosk-idle-reset.timer on every touch event";
      wantedBy = [ "multi-user.target" ];
      after = [ "cage-tty1.service" ];
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "idle-watchdog" (builtins.readFile ./scripts/idle-watchdog.sh);
        Restart = "always";
        RestartSec = "5s";
        Environment = [ "TOUCH_DEVICE=/dev/input/kiosk-touch" ];
      };
      # Belt-and-suspenders alongside kiosk-idle-reset.timer's own
      # StartLimitIntervalSec=0 above: with that fixed this shouldn't
      # crash in the first place, but a service that can permanently
      # fail (its own default restart-rate limit) would silently and
      # totally disable idle-reset until the next reboot/deploy, with no
      # on-screen symptom at all -- not worth leaving capped even as a
      # secondary safety net.
      unitConfig.StartLimitIntervalSec = 0;
    };

    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = cfg.extraGroups;
    };
  };
}

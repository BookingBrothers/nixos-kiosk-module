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

  enabledNavButtons = lib.filter (b: b.enable) (lib.attrValues cfg.navigation.buttons);

  enableNavExtension =
    cfg.navigation.onScreenKeyboard.enable || enabledNavButtons != [ ] || cfg.navigation.allowedHosts != null;

  # The one generated file in the on-screen-keyboard/nav extension: pure
  # data assignments (no control flow, nothing script-like) handing this
  # host's resolved config to the otherwise fully static nav-buttons.js/
  # nav-guard.js content scripts.
  kioskExtensionConfig = pkgs.writeText "config.js" ''
    // attrValues/filter iterate in attribute-name (lexicographic) order,
    // so buttons render left-to-right sorted by their Nix-level key --
    // "back" before "home" is exactly why the two built-ins are named
    // that, not e.g. "1-back"/"2-home". Name your own entries with that
    // in mind if display order matters to you.
    window.__KIOSK_NAV_BUTTONS__ = ${
      builtins.toJSON (
        map (b: {
          inherit (b) icon action;
        }) enabledNavButtons
      )
    };
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

  # ---- generic Firefox extensions API -------------------------------
  #
  # `cfg.extensions` is an attrsOf submodule, the same shape nixpkgs uses
  # for e.g. systemd.services.<name> -- the attribute NAME (e.g.
  # "uBlockOrigin") is just a Nix-level handle for overriding one entry;
  # the extension's real identity is its own `id` option. uBlockOrigin/
  # consentOMatic/autoscrollShorts below are the option's own `default`
  # value, not special-cased Nix code -- add your own extension the
  # exact same way: `services.kiosk-mode.extensions.myThing = { id =
  # "..."; };`, or turn a built-in one off with
  # `services.kiosk-mode.extensions.uBlockOrigin.enable = false;`.
  enabledExtensions = lib.filterAttrs (_: ext: ext.enable) cfg.extensions;

  # Extensions that ship their own (necessarily unsigned) xpi need the
  # signature-check bypass and firefox-devedition, same as the on-screen-
  # keyboard extension above.
  xpiExtensions = lib.filterAttrs (_: ext: ext.xpi != null) enabledExtensions;
  needsUnsignedInstall = enableNavExtension || xpiExtensions != { };

  # Computed once, up front, rather than relying on the module system to
  # concatenate a list-typed leaf (Extensions.Install) across several
  # separate `lib.mkMerge` blocks -- programs.firefox.policies is a
  # loosely-typed JSON passthrough, and depending on more than one
  # definition merging into ONE list correctly there is a real footgun,
  # not a hypothetical one.
  installXpiUrls =
    lib.optional enableNavExtension "file://${kioskKeyboardXpi}"
    ++ map (ext: "file://${ext.xpi}") (lib.attrValues xpiExtensions);

  extensionSettingsFromApi = lib.mapAttrs' (
    _: ext:
    lib.nameValuePair ext.id (
      {
        installation_mode = ext.installationMode;
        private_browsing = ext.privateBrowsing;
      }
      // lib.optionalAttrs (ext.installUrl != null) { install_url = ext.installUrl; }
      // ext.settings
    )
  ) enabledExtensions;

  # ---- shared browser.storage.sync seed db ---------------------------
  #
  # Some extensions gate first-run behavior (e.g. an onboarding tab) on a
  # browser.storage.sync flag that defaults to "show it", and flips
  # itself off right after. On a normal install that's a harmless
  # one-time thing, but this module wipes and recreates the whole
  # profile on every single restart, so without pre-seeding that flag it
  # re-triggers EVERY restart, stealing the display from `cfg.url` (this
  # is exactly what consentOMatic below needs its own `storageSyncSeed`
  # for).
  #
  # storage.sync's on-disk format (for a profile that's never actually
  # signed in to Firefox Sync) is ONE SQLite database per profile, not
  # one per extension -- `storage_sync_data` is a single table keyed by
  # extension id -- so seeds from every extension that sets
  # `storageSyncSeed` are merged into one shared db here, not shipped as
  # separate files that would just overwrite each other.
  #
  # Schema/table names/data shape are copied verbatim from a real
  # Firefox profile's storage-sync-v2.sqlite after letting an extension
  # (Consent-O-Matic) flip its own flag once and inspecting the result --
  # Firefox's on-disk format for this API isn't documented anywhere
  # reliable.
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
  extensionsWithSeed = lib.filterAttrs (_: ext: ext.storageSyncSeed != null) enabledExtensions;

  # SQL string literals escape a single quote by doubling it; toJSON
  # never itself emits one (JSON strings are double-quoted), but a seed
  # value could still contain a literal apostrophe.
  sqlQuote = s: "'" + (lib.replaceStrings [ "'" ] [ "''" ] s) + "'";

  storageSyncSeedDb =
    if extensionsWithSeed == { } then
      null
    else
      pkgs.runCommand "kiosk-storage-sync-seed.sqlite" { nativeBuildInputs = [ pkgs.sqlite ]; } ''
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
        SQL
        ${lib.concatMapStringsSep "\n" (
          ext:
          ''sqlite3 "$out" "INSERT INTO storage_sync_data (ext_id, data, sync_change_counter) VALUES (${sqlQuote ext.id}, ${sqlQuote (builtins.toJSON ext.storageSyncSeed)}, 1);"''
        ) (lib.attrValues extensionsWithSeed)}
      '';

  extensionSubmodule = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to install this extension.";
        };

        id = lib.mkOption {
          type = lib.types.str;
          example = "uBlock0@raymondhill.net";
          description = ''
            The extension's real Firefox/gecko extension ID
            (browser_specific_settings.gecko.id in its manifest.json) --
            what Firefox's ExtensionSettings policy actually keys on. The
            attribute name (`${name}`) is only a Nix-level handle for
            overriding this one entry from your own configuration.
          '';
        };

        installationMode = lib.mkOption {
          type = lib.types.enum [
            "allowed"
            "blocked"
            "force_installed"
            "normal_installed"
          ];
          default = "normal_installed";
          description = ''
            Firefox's ExtensionSettings `installation_mode` -- see
            Mozilla's enterprise policy documentation.
            "normal_installed" ships pre-installed and enabled but stays
            a regular extension the user can disable/remove via
            about:addons; "force_installed" cannot be removed.
          '';
        };

        installUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi";
          description = ''
            Where Firefox fetches this extension from. Leave null for an
            AMO-hosted extension -- as of Firefox 153, install_url is
            optional for those; Firefox resolves and installs the latest
            version straight from AMO by `id` alone. Confirmed live that
            the explicit install_url form
            (addons.mozilla.org/.../latest.xpi) silently failed to
            trigger an install at all on a current Firefox devedition
            build despite working network access to AMO -- prefer
            leaving this null unless you have a specific reason not to
            (e.g. a non-AMO-hosted xpi URL).

            Ignored when `xpi` is set -- that always installs via a
            local file:// URL instead.
          '';
        };

        xpi = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = ''
            A locally-built xpi (e.g. an extension you author yourself,
            like this module's own on-screen keyboard) to force-install
            via a file:// URL, instead of fetching one from `installUrl`.
            Setting this on ANY extension switches the whole profile to
            firefox-devedition and unlocks xpinstall.signatures.required
            -- plain Firefox hard-enforces AMO signature checks with no
            override, and devedition is the one nixpkgs Firefox variant
            that doesn't.
          '';
        };

        privateBrowsing = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether this extension is allowed to run in a private-
            browsing window. This module forces permanent private
            browsing (browser.privatebrowsing.autostart), and Firefox
            disables extensions inside private windows by default --
            almost every extension needs this true to do anything at
            all, which is why it defaults to true here rather than
            false.
          '';
        };

        storageSyncSeed = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
          default = null;
          example = {
            debugFlags.autoOpenOptionsTab = false;
          };
          description = ''
            Data to pre-seed into this extension's browser.storage.sync
            before Firefox first starts, for an extension that gates
            first-run behavior (e.g. an onboarding tab) on a flag that
            would otherwise reset to its default every single restart.
            Merged with every other extension's own seed (if any) into
            one shared database -- see this module's own
            `storageSyncSeedDb` for why that has to be shared rather than
            per-extension, and its own PRAGMA user_version comment for a
            correctness gotcha worth reading before relying on this for
            a new extension.
          '';
        };

        settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Extra keys merged directly into this extension's ExtensionSettings entry, verbatim.";
        };
      };
    }
  );
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
              example = "1234";
              description = "Matched against ATTRS{idVendor} (services.udev.extraRules).";
            };
            productId = lib.mkOption {
              type = lib.types.str;
              example = "5678";
              description = "Matched against ATTRS{idProduct} (services.udev.extraRules).";
            };
            calibrationMatrix = lib.mkOption {
              type = lib.types.submodule {
                options = lib.genAttrs [ "normal" "left" "right" "inverted" ] (
                  rotation:
                  lib.mkOption {
                    type = lib.types.str;
                    default = "1 0 0 0 1 0"; # identity -- no adjustment
                    example = "0 -1 1 1 0 0";
                    description = ''
                      LIBINPUT_CALIBRATION_MATRIX (same X.Org Coordinate
                      Transformation Matrix convention libinput uses) for
                      `screenRotation = "${rotation}"`. Automatically
                      selected by that option's current value, so a host
                      that only ever runs "normal" never needs to touch
                      this at all; a host that rotates needs to override
                      whichever rotations it actually uses. Defaults to
                      the identity matrix (no adjustment) for every
                      rotation, which is only actually CORRECT for
                      "normal" -- left as the default for the others too
                      since there's no universally-right guess for a 90/
                      180/270-degree correction: on one real device, the
                      "obvious" CCW/CW pairing for a 90-degree rotation
                      turned out backwards for drag-gesture direction
                      even though tap POSITION looked fine, only caught
                      by testing an actual drag rather than a tap. An
                      unrotated identity matrix on an actually-rotated
                      screen is a visible, fixable-by-testing
                      misalignment, not a silently-plausible-looking
                      wrong value, which is why it's still a safe
                      default to ship rather than making every
                      non-"normal" rotation a hard error.
                    '';
                  }
                );
              };
              default = { };
              description = ''
                Per-rotation LIBINPUT_CALIBRATION_MATRIX strings -- see
                each rotation's own field description. The one actually
                applied is picked automatically from `screenRotation`.
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

      # Real, user-extensible API (attrsOf submodule, same shape as
      # `extensions` above) rather than two hardcoded booleans -- `back`
      # and `home` below are this option's own built-in entries, not
      # special-cased code, so add your own the same way:
      # `services.kiosk-mode.navigation.buttons.settings = { icon = "⚙";
      # action = "https://example.com/settings"; };`, and turn a built-in
      # one off the same way any entry overrides another:
      # `services.kiosk-mode.navigation.buttons.home.enable = false;`.
      buttons = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether to show this button.";
              };

              icon = lib.mkOption {
                type = lib.types.str;
                example = "←";
                description = ''
                  A single glyph rendered as the button's content. Any
                  Unicode character works -- arrows, symbols, emoji (e.g.
                  U+2190 "←" for back, U+2302 "⌂" for home). Browse
                  https://unicode-table.com or similar for something to
                  pick by name/category rather than committing this
                  module to bundling and versioning an actual icon-font
                  dependency for what's normally a one-or-two-button bar.
                '';
              };

              action = lib.mkOption {
                type = lib.types.str;
                example = "back";
                description = ''
                  What tapping this button does. Either the literal
                  string "back" (calls history.back(), and the button
                  dims/disables itself when there's nothing to go back
                  to -- see kiosk-keyboard-extension/nav-buttons.js), or
                  any URL to navigate to instead.
                '';
              };
            };
          }
        );
        default = { };
        description = ''
          Small floating buttons, top-left corner, for kiosks with no
          browser chrome at all (no back/home button, no swipe-back
          gesture support in cage/Wayland) -- keyed by an arbitrary short
          Nix-level name, same convention as `extensions` above. `back`
          and `home` ship built in but OFF by default (most dashboards,
          e.g. a read-only display, have no subpages to navigate out of
          in the first place); turn either on with
          `services.kiosk-mode.navigation.buttons.<back|home>.enable = true;`.
        '';
      };

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

    extensions = lib.mkOption {
      type = lib.types.attrsOf extensionSubmodule;
      # The three built-in entries (uBlockOrigin/consentOMatic/
      # autoscrollShorts) are NOT this option's own `default` -- deliberately.
      # An attrsOf-submodule option's declaration-level `default` is one
      # single low-priority DEFINITION of the whole attrset; it does NOT
      # get decomposed and re-merged field-by-field against a caller's
      # own `extensions.autoscrollShorts.enable = true;` the way you'd
      # expect (confirmed live: doing it that way, overriding just
      # `enable` on a built-in entry made its `id` "accessed but has no
      # value defined", because the caller's definition of that key wins
      # OUTRIGHT over the option's default entry for that same key,
      # rather than merging with it field-by-field). The three entries
      # are instead set via `lib.mkDefault` down in `config`, at the same
      # priority (1000) plain option defaults use -- which DOES correctly
      # merge per-field against a caller's own definitions, because at
      # that point they're just an ordinary extra module contributing to
      # the same nested option, not the option's own baked-in default.
      default = { };
      description = ''
        Firefox extensions to install into the kiosk profile, keyed by an
        arbitrary short Nix-level name. `uBlockOrigin`/`consentOMatic`/
        `autoscrollShorts` ship built in (set via `lib.mkDefault` in this
        module's own `config`, not special-cased elsewhere) -- turn any
        of them off the same way you'd override any other default:
        `services.kiosk-mode.extensions.uBlockOrigin.enable = false;`.
        Add your own the same way:

        ```nix
        services.kiosk-mode.extensions.myAdBlocker.id = "...@example.com";
        ```

        uBlock Origin is on by default: worth having on any kiosk
        rendering real third-party web content. Consent-O-Matic is on by
        default too (auto-answers GDPR cookie-consent dialogs): a kiosk
        nobody is standing at to click "Accept" through a modal cookie
        banner needs it handled automatically. "Autoscroll Shorts" (auto-
        advances to the next
        YouTube Short when the current one ends) is off by default --
        unlike the other two, it's only useful on a kiosk that actually
        shows YouTube Shorts; picked over several similar extensions
        specifically because it has no storage/settings/toggle at all
        (verified by reading its full content script), so there's nothing
        to fight against this module's wipe-every-restart profile, unlike
        alternatives that either default off or reopen their own install
        tab every restart via a storage.local flag (much harder to
        pre-seed than storage.sync -- see `storageSyncSeed`'s own
        description for why storage.sync is already the harder case).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.idleTimeoutMinutes == 0 || cfg.touch != null;
        message = "services.kiosk-mode.idleTimeoutMinutes > 0 requires services.kiosk-mode.touch to be set -- nothing to watch for activity otherwise";
      }
    ];

    # The three built-in extensions -- see the `extensions` option's own
    # comment for why these live here (mkDefault, priority 1000) rather
    # than in that option's declaration-level `default`.
    #
    # EACH FIELD gets its own `lib.mkDefault`, not one `mkDefault` wrapping
    # the whole `{ id = ...; ... }` attrset -- confirmed live (isolated
    # from the rest of this module, in the plain `lib.evalModules`
    # sense) that those are NOT equivalent for an attrsOf-submodule
    # option: wrap the whole attrset, and a caller overriding just
    # `.enable` makes `.id` "accessed but has no value defined" --
    # mkDefault on the outer value doesn't get decomposed field-by-field
    # against a caller's own separate, more specific definition of the
    # SAME entry the way you'd expect. Wrapping each field individually
    # doesn't have this problem, because each field then arrives as its
    # own independent, already-leaf-level definition, exactly like any
    # other option default.
    services.kiosk-mode.extensions = {
      uBlockOrigin = {
        # A real, AMO-hosted, normally-signed extension -- installed
        # straight from addons.mozilla.org, no signature-bypass needed.
        id = lib.mkDefault "uBlock0@raymondhill.net";
      };
      consentOMatic = {
        id = lib.mkDefault "gdpr@cavi.au.dk"; # per rycee/nur-expressions' generated-firefox-addons.nix; AMO's own listing page doesn't surface it directly
        storageSyncSeed = lib.mkDefault {
          debugFlags.autoOpenOptionsTab = false;
        };
      };
      autoscrollShorts = {
        id = lib.mkDefault "{96d7f719-11f8-427d-898f-51b4a3803952}"; # from the actual published xpi's manifest.json, not guessed
        enable = lib.mkDefault false;
      };
    };

    # The two built-in nav buttons -- same per-field-mkDefault reasoning
    # as `extensions` above applies here too (attrsOf submodule, built-in
    # entries need it or a caller overriding just `.enable` breaks `.icon`/
    # `.action`).
    services.kiosk-mode.navigation.buttons = {
      back = {
        icon = lib.mkDefault "←";
        action = lib.mkDefault "back";
        enable = lib.mkDefault false; # matches this button's previous default (enableBackButton ? false)
      };
      home = {
        icon = lib.mkDefault "⌂";
        action = lib.mkDefault cfg.url; # overridable to point somewhere other than `url` if that's ever wanted
        enable = lib.mkDefault false; # matches this button's previous default (enableHomeButton ? false)
      };
    };

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
      SUBSYSTEM=="input", ATTRS{idVendor}=="${cfg.touch.vendorId}", ATTRS{idProduct}=="${cfg.touch.productId}", ENV{LIBINPUT_CALIBRATION_MATRIX}="${cfg.touch.calibrationMatrix.${cfg.screenRotation}}"
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
      # any unsigned (locally-built) extension at all. Plain firefox
      # hard-enforces AMO signature checks with no override -- only worth
      # the non-default package when actually needed.
      package = if needsUnsignedInstall then pkgs.firefox-devedition else pkgs.firefox;
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
        (lib.mkIf needsUnsignedInstall {
          Preferences."xpinstall.signatures.required" = {
            Value = false;
            Status = "locked";
          };
          Extensions.Install = installXpiUrls;
        })
        (lib.mkIf enableNavExtension {
          ExtensionSettings."kiosk-keyboard@kiosk-mode.local" = {
            installation_mode = "allowed";
            # Required for BOTH `mode` values, not just "custom" --
            # scripts/firefox-kiosk.sh sets
            # browser.privatebrowsing.autostart=true unconditionally, and
            # Firefox disables extensions in private-browsing windows by
            # default.
            private_browsing = true;
          };
        })
        { ExtensionSettings = extensionSettingsFromApi; }
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
      # Same reasoning as KIOSK_EXTENSION_XPI above -- only referenced by
      # scripts/firefox-kiosk.sh via this env var, so this is also what
      # makes a *content* change to that db (e.g. a new extension setting
      # storageSyncSeed) actually reach a running kiosk on redeploy.
      // lib.optionalAttrs (storageSyncSeedDb != null) {
        KIOSK_STORAGE_SYNC_SEED_DB = "${storageSyncSeedDb}";
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

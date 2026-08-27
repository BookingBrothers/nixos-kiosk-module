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

  # Hostname out of an http(s) URL, or null for anything else (a bare
  # host, a non-http(s) scheme, "back") -- deliberately narrow rather
  # than a general-purpose URL parser, since every caller here already
  # knows its input is either a real navigation target or the literal
  # "back" sentinel.
  hostOf =
    url:
    let
      m = builtins.match "https?://([^/:]+).*" url;
    in
    if m != null then builtins.head m else null;

  # Every host this module's OWN config already navigates the kiosk to
  # on purpose (the home url, every enabled nav button's target) --
  # auto-unioned into allowedHosts below so an operator adding a nav
  # button doesn't *also* have to separately remember to list its host,
  # the same gap that made the 😁 button above briefly get redirected
  # straight back home the instant allowedHosts' own redirect-on-
  # disallowed-host check shipped (a host missing from the list is
  # indistinguishable from an actual escape attempt -- confirmed live).
  autoAllowedHosts = lib.filter (h: h != null) (
    map hostOf ([ cfg.url ] ++ map (b: b.action) (lib.filter (b: b.action != "back") enabledNavButtons))
  );

  # null stays null (feature off entirely) -- autoAllowedHosts has
  # nothing to union into if the operator hasn't opted into host
  # restriction at all.
  effectiveAllowedHosts =
    if cfg.navigation.allowedHosts == null then
      null
    else
      lib.unique (cfg.navigation.allowedHosts ++ autoAllowedHosts);

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
    // effectiveAllowedHosts, not the raw allowedHosts option -- see that
    // binding's own comment for why (auto-unions every host this
    // module's own config already navigates to on purpose).
    window.__KIOSK_ALLOWED_HOSTS__ = ${
      if effectiveAllowedHosts != null then builtins.toJSON effectiveAllowedHosts else "null"
    };
    // Redirect target for nav-guard.js's on-load check (already-landed-
    // on-a-disallowed-host, as opposed to the click-time check
    // __KIOSK_ALLOWED_HOSTS__ alone drives) -- same url as the home nav
    // button's own default action.
    window.__KIOSK_HOME_URL__ = ${builtins.toJSON cfg.url};
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

  # ---- Firefox site-permission prompts (camera/microphone/location/...) --
  #
  # Unlike `extensions`/`navigation.buttons` above, this is NOT an
  # attrsOf-submodule -- Firefox's Permissions policy has exactly seven
  # real sub-keys (Camera, Microphone, Location, Notifications, Autoplay,
  # VirtualReality, ScreenShare; confirmed against Mozilla's own
  # policy-templates docs, not guessed), a closed set nothing else can
  # extend. An open attrsOf here would just trade "Firefox silently
  # ignores a typo'd key" for "this module silently ignores a typo'd
  # key" -- a fixed field per real permission type lets the option
  # system catch `cfg.permissions.cammera` at eval time instead.
  #
  # Each one is off (`enable = false`) unless explicitly configured --
  # this module has no business deciding e.g. every kiosk's Location
  # prompt behavior on its own. Once enabled, `blockNewRequests`
  # defaults to true: the entire point of this option is "this one site
  # gets it silently, nobody else even sees a prompt" (a kiosk has no
  # user standing by to click through one), so the default has to make
  # that true without extra config, not just make it *possible*.
  mkPermissionOption =
    firefoxName:
    lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this module manages Firefox's ${firefoxName} permission prompt at all. When false, Firefox's own default (per-site prompt) behavior is untouched.";
          };
          allow = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "https://example.com" ];
            description = ''
              Origins (scheme+host+port, not bare hostnames) granted
              ${firefoxName} automatically, no prompt. May require
              `services.kiosk-mode.privateBrowsing = false` to actually
              take effect -- confirmed via an isolated local A/B repro
              for Camera/Microphone specifically (a genuine
              getUserMedia()-based site got a real NotAllowedError
              instead of silent access while private browsing was
              forced on, which it is by default; the same origin
              worked with it off). Not independently verified for
              ${firefoxName}, but very likely the same: every
              `Permissions.<Type>` entry is implemented through the
              same underlying permission-manager mechanism, which
              isn't honored inside a permanently-private session
              (`blockNewRequests`, a plain global pref, is unaffected
              either way). See `privateBrowsing`'s own description.
            '';
          };
          block = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "https://example.org" ];
            description = "Origins explicitly denied ${firefoxName}, no prompt -- for carving out an exception when `blockNewRequests` is false. Redundant with (and overridden by) `blockNewRequests = true`, which already denies every origin not in `allow`.";
          };
          blockNewRequests = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Deny ${firefoxName} outright (no prompt at all) for every origin not listed in `allow`. This is what makes `allow` an allowlist rather than just a way to skip the prompt for one more site -- turn it off if unlisted origins should still get Firefox's normal prompt.";
          };
          locked = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Prevent changing ${firefoxName} settings via about:preferences. Defaults on for the same reason DisableDeveloperTools is unconditional -- one less kiosk-escape/reconfiguration surface, even though this mode's hidden chrome makes about:preferences hard to reach in the first place.";
          };
        };
      };
      default = { };
      description = "Firefox's ${firefoxName} permission prompt.";
    };

  # Autoplay is shaped differently in Firefox's own policy (a global
  # `Default` for unmatched origins instead of `BlockNewRequests`) --
  # modeled as its own option rather than forcing it through
  # mkPermissionOption's shape and hoping the mismatch goes unnoticed.
  autoplayPermission = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether this module manages Firefox's Autoplay permission at all. When false, Firefox's own default is untouched.";
        };
        allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "https://example.com" ];
          description = "Origins allowed to autoplay audio+video.";
        };
        block = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Origins explicitly denied autoplay, regardless of `default`.";
        };
        default = lib.mkOption {
          type = lib.types.enum [
            "allow-audio-video"
            "block-audio"
            "block-audio-video"
          ];
          default = "block-audio-video";
          description = "Autoplay behavior for every origin not covered by `allow`/`block` -- defaults to blocking outright (silent, no prompt: Firefox's autoplay policy was never prompt-based to begin with), same reasoning as the other permissions' `blockNewRequests` default.";
        };
        locked = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Prevent changing autoplay settings via about:preferences.";
        };
      };
    };
    default = { };
    description = "Firefox's Autoplay permission (audio+video autoplay-with-sound).";
  };

  # Also its own option rather than forced through mkPermissionOption's
  # shape: it maps to a completely different Firefox policy (Cookies,
  # not Permissions -- see storageAccessPolicy's own comment below for
  # why), with a `behavior` enum instead of `blockNewRequests`.
  storageAccessPermission = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether this module manages the Storage Access API prompt
            (`document.requestStorageAccess()` -- "<site> wants to use
            cookies from <other site> while browsing this site") at
            all. When false, Firefox's own default is untouched.
          '';
        };
        allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "https://example.com" ];
          description = "Origins always allowed cookies, including as a third party -- no prompt.";
        };
        block = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Origins always denied cookies -- no prompt.";
        };
        behavior = lib.mkOption {
          type = lib.types.enum [
            "accept"
            "reject-foreign"
            "reject"
            "limit-foreign"
            "reject-tracker"
            "reject-tracker-and-partition-foreign"
          ];
          default = "reject-foreign";
          description = ''
            Firefox's global third-party-cookie policy for every origin
            not covered by `allow`/`block` -- see Mozilla's own Cookies
            policy documentation for what each value does. Defaults to
            "reject-foreign" (block third-party cookies outright, no
            per-request negotiation) rather than Firefox's own current
            default ("reject-tracker-and-partition-foreign", the
            partition-and-prompt-driven Total Cookie Protection model)
            specifically because partitioning is itself what the
            Storage Access API prompt exists to negotiate around --
            "reject-foreign" has no such negotiation step, so there's
            nothing left to prompt about. NOT confirmed live to
            actually suppress the prompt, unlike this module's other
            `permissions.*` entries -- Mozilla's docs don't spell out
            the exact relationship between this setting and that
            specific dialog. Verify against a real site that triggers
            it before relying on this.
          '';
        };
        locked = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Prevent changing cookie settings via about:preferences.";
        };
      };
    };
    default = { };
    description = "Firefox's third-party-cookie / Storage Access API behavior.";
  };

  # Maps this module's own field names to Firefox's real Permissions
  # policy JSON, and drops any permission left at `enable = false`
  # entirely -- an unconfigured permission must produce NO policy key at
  # all, not an empty/default one, or every kiosk using this module
  # would suddenly start silently blocking camera/location/etc. for
  # everyone, unasked.
  permissionPolicyFor =
    firefoxName: p:
    lib.optionalAttrs p.enable {
      ${firefoxName} = {
        Allow = p.allow;
        Block = p.block;
        BlockNewRequests = p.blockNewRequests;
        Locked = p.locked;
      };
    };

  permissionsPolicy =
    permissionPolicyFor "Camera" cfg.permissions.camera
    // permissionPolicyFor "Microphone" cfg.permissions.microphone
    // permissionPolicyFor "Location" cfg.permissions.location
    // permissionPolicyFor "Notifications" cfg.permissions.notifications
    // permissionPolicyFor "VirtualReality" cfg.permissions.virtualReality
    // permissionPolicyFor "ScreenShare" cfg.permissions.screenShare
    // lib.optionalAttrs cfg.permissions.autoplay.enable {
      Autoplay = {
        Allow = cfg.permissions.autoplay.allow;
        Block = cfg.permissions.autoplay.block;
        Default = cfg.permissions.autoplay.default;
        Locked = cfg.permissions.autoplay.locked;
      };
    };

  # NOT part of Firefox's Permissions policy (confirmed against
  # Mozilla's own docs -- there's no Permissions.StorageAccess entry),
  # because the underlying prompt this maps to isn't a Permissions.*
  # one at all: `document.requestStorageAccess()` (the "<site> wants to
  # use cookies from <other site> while browsing this site" dialog) is
  # governed by the separate Cookies policy instead, which has no
  # BlockNewRequests-equivalent field -- only a single global `Behavior`
  # enum plus per-origin Allow/Block/AllowSession override lists.
  # "reject-foreign" (hard, unconditional third-party-cookie blocking,
  # no negotiation) is this module's best-effort mapping of "block
  # everyone not explicitly allowed, no prompt" onto that narrower
  # vocabulary -- UNLIKE the Permissions.<Type> family above, this has
  # NOT been confirmed live to actually suppress the prompt (Mozilla's
  # docs don't spell out the exact relationship between Behavior and
  # this specific dialog the way they do for BlockNewRequests). Verify
  # against a real site that triggers it before relying on this.
  storageAccessPolicy = lib.optionalAttrs cfg.permissions.storageAccess.enable {
    Cookies = {
      Allow = cfg.permissions.storageAccess.allow;
      Block = cfg.permissions.storageAccess.block;
      Behavior = cfg.permissions.storageAccess.behavior;
      Locked = cfg.permissions.storageAccess.locked;
    };
  };

  # Firefox's Handlers policy, per Mozilla's own docs: "If you don't
  # want to have a default handler, use an empty object for the first
  # handler." Combined with ask=false, this is the documented way to
  # make Firefox treat a scheme as having nothing to hand off to and
  # nothing to ask about, rather than falling back to its own "choose
  # an application" dialog.
  # allowedSchemes subtracted here, not left for the option merge itself
  # -- plain NixOS list options only ever concatenate multiple
  # definitions together, they can't express "all of this EXCEPT these"
  # the way an explicit subtraction step can.
  effectiveBlockedSchemes = lib.subtractLists cfg.navigation.allowedSchemes cfg.navigation.blockedSchemes;

  blockedSchemesPolicy = lib.optionalAttrs (effectiveBlockedSchemes != [ ]) {
    Handlers.schemes = lib.genAttrs effectiveBlockedSchemes (_scheme: {
      action = "useHelperApp";
      ask = false;
      # A real handler, not `[ { } ]` -- confirmed via an isolated local
      # repro that an empty-object "no default handler" entry (Mozilla's
      # own documented way to configure one) does NOT actually suppress
      # Firefox's native "choose an application" dialog despite
      # ask=false; only giving it a genuine, concrete default to
      # silently use does. uriTemplate must be https and contain a
      # literal %s (Mozilla's own requirement) -- appended as a harmless
      # URL fragment, never actually substituted/visited in practice
      # (also confirmed live: the current tab's own location never
      # changes when this fires, so this handler target is only ever
      # reached if Firefox's behavior here changes in some future
      # version). Points at this kiosk's own `url` rather than e.g. a
      # reserved/dead domain so that IF it's ever actually visited, a
      # visitor sees the kiosk's own home page, not a foreign domain or
      # a blank connection-error page.
      handlers = [
        {
          name = "kiosk-mode";
          uriTemplate = "${cfg.url}#%s";
        }
      ];
    });
  };
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
        `privateBrowsing` below applies either way, regardless of this
        setting.
      '';
    };

    privateBrowsing = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Force permanent private browsing (browser.privatebrowsing.autostart)
        regardless of `mode`. On by default: combined with this module
        wiping the whole profile on every restart anyway, it also keeps
        history/cookies/cache from persisting *within* one continuous
        session (between restarts, e.g. across an idle-reset-free
        run) -- a visitor's browsing doesn't linger for the next one to
        see, and nothing shows up in autocomplete.

        CORRECTNESS-CRITICAL if you use `permissions.<type>.allow`:
        confirmed via an isolated local A/B repro (same Firefox build,
        same exact Permissions.Camera/Microphone policy JSON, same
        getUserMedia() call) that leaving this on silently breaks that
        `allow` list for any real getUserMedia()-based site -- Firefox's
        enterprise-policy Allow exception is implemented through the
        same permission-manager mechanism as a real user's remembered
        site permission, which isn't honored inside a permanently-
        private session (`blockNewRequests`, a plain global pref, still
        works fine either way -- it's specifically the per-origin Allow
        exception that doesn't apply). Set this to false on any host
        that needs `permissions.*` to actually work for such a site;
        the trade-off is the paragraph above no longer holding true
        *within* a session (still wiped clean on every restart either
        way).
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

    camera = lib.mkOption {
      default = null;
      description = ''
        Declares a built-in/attached camera and sets up a rotation-
        corrected virtual device for it, tracking `screenRotation`, at
        the stable path /dev/video-follow-rotation. null (the default)
        means no camera handling at all.

        Same reasoning as `touch` above: a camera mounted in a fixed
        physical orientation relative to the chassis has no idea the
        *display* just got told to rotate, and this isn't something a
        web page or browser setting can fix on its own.

        Implemented via v4l2loopback: a relay service reads from the
        real camera (found via `vendorId`/`productId`, since a camera
        with no persistent USB serial can't get a stable /dev/v4l/by-id
        symlink from udev's own built-in rules) and continuously writes
        frames into a virtual v4l2loopback device -- filtered through
        `rotationFilter.<screenRotation>` -- exposed at
        /dev/video-follow-rotation regardless of whatever raw
        /dev/videoN index either device ends up with. This module
        doesn't touch or replace the real camera's own device node
        (/dev/video0 etc. keep working exactly as before) -- anything
        that wants the rotated feed has to open
        /dev/video-follow-rotation explicitly instead.
      '';
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            vendorId = lib.mkOption {
              type = lib.types.str;
              example = "058f";
              description = ''
                Matched against ATTRS{idVendor} (services.udev.extraRules),
                same convention as touch.vendorId above -- identifies the
                real camera so the relay keeps reading from it regardless
                of which /dev/videoN index the kernel happens to assign.
              '';
            };
            productId = lib.mkOption {
              type = lib.types.str;
              example = "5608";
              description = "Matched against ATTRS{idProduct} (services.udev.extraRules).";
            };
            inputFormat = lib.mkOption {
              type = lib.types.str;
              default = "mjpeg";
              description = "ffmpeg's v4l2 demuxer -input_format when reading the real camera.";
            };
            videoSize = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "1280x720";
              description = "ffmpeg's -video_size when reading the real camera. null lets ffmpeg negotiate whatever mode the camera defaults to.";
            };
            framerate = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.unsigned;
              default = null;
              example = 15;
              description = "ffmpeg's -framerate when reading the real camera. null lets ffmpeg negotiate the camera's own default.";
            };
            rotationFilter = lib.mkOption {
              type = lib.types.submodule {
                options = lib.genAttrs [ "normal" "left" "right" "inverted" ] (
                  rotation:
                  lib.mkOption {
                    type = lib.types.str;
                    default = "null"; # ffmpeg's own no-op filter -- identity, no adjustment
                    example = "transpose=1";
                    description = ''
                      ffmpeg `-vf` filter graph applied to the real
                      camera's feed for `screenRotation = "${rotation}"`
                      before writing it to /dev/video-follow-rotation.
                      ",format=yuv420p" is appended automatically after
                      this value -- an MJPEG source decodes to a pixel
                      format (yuvj420p/yuvj422p) with no direct V4L2
                      fourcc equivalent, so writing straight to the v4l2
                      muxer fails outright without forcing a real
                      V4L2-mappable format first (confirmed live: ffmpeg
                      error "Unknown V4L2 pixel format equivalent for
                      yuvj422p") -- no need to add it yourself.
                      Automatically selected by that option's current
                      value, same convention as touch.calibrationMatrix
                      above. Defaults to "null" (ffmpeg's literal no-op
                      filter, i.e. no adjustment) for every rotation --
                      only actually correct for "normal"; a rotating
                      host needs to work out the right value for the
                      rotations it uses (ffmpeg's `transpose` filter: 1
                      = 90deg clockwise, 2 = 90deg counter-clockwise, or
                      chain two of them for 180 -- verify against a real
                      screenshot/photo the same way as touch calibration,
                      not by assuming a direction, since
                      touch.calibrationMatrix's own description above
                      records a real case of the "obvious" CW/CCW
                      pairing turning out backwards for one axis on real
                      hardware).
                    '';
                  }
                );
              };
              default = { };
              description = ''
                Per-rotation ffmpeg filter strings -- see each
                rotation's own field description. The one actually
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
                  [unicode-table.com](https://unicode-table.com) or
                  similar for something to pick by name/category rather
                  than committing this module to bundling and versioning
                  an actual icon-font dependency for what's normally a
                  one-or-two-button bar.
                '';
              };

              action = lib.mkOption {
                type = lib.types.str;
                example = "https://example.com/";
                description = ''
                  What tapping this button does. Any URL navigates the
                  kiosk there -- this is the normal case, and what the
                  built-in `home` button uses (its own `action` is set to
                  this module's `url`). The one special value is the
                  literal string `"back"` (used by the built-in `back`
                  button), which calls history.back() instead of
                  navigating to a literal page called "back", and makes
                  the button dim/disable itself when there's nothing to
                  go back to -- see kiosk-keyboard-extension/nav-buttons.js.
                '';
              };
            };
          }
        );
        default = { };
        defaultText = lib.literalExpression ''
          {
            back = { icon = "←"; action = "back"; enable = false; };
            home = { icon = "⌂"; action = config.services.kiosk-mode.url; enable = false; };
          }
        '';
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
          A list of hostnames, or null to disable. When set, this does
          two things: blocks clicking any link to a hostname NOT in the
          list (or a subdomain of one) -- a direct kiosk-escape route
          needing no keyboard trick at all (e.g. an embedded video's own
          "watch on the original site" button, or a mailto: link opening
          a native "choose an application" dialog) -- and, separately,
          redirects back to `url` if the kiosk ends up on a disallowed
          host by any OTHER means (a script-driven navigation, a form
          submit, a meta-refresh, or a server-side redirect from an
          otherwise-allowed page -- none of which a click listener alone
          catches). Doesn't touch legitimately embedded third-party
          content (iframes) -- only intercepts a visitor actually
          clicking through to leave the site, or the top-level document
          itself ending up elsewhere. A list rather than one hostname
          since a site can legitimately span more than one domain (e.g.
          a short-link domain alongside the main one, or a companion
          platform it links out to).

          You don't need to list `url`'s own host, or any enabled
          `navigation.buttons.<name>.action` URL's host, here yourself
          -- every host this module's own config already navigates the
          kiosk to on purpose is unioned in automatically, for both
          checks above. Forgetting one used to mean either a real link
          silently not working (the click-block check) or, once the
          redirect check shipped, a configured nav button instantly
          bouncing back to `url` the moment it was tapped -- a host
          missing from this list looks identical to an actual escape
          attempt either way, so this module tracks its own known-good
          hosts rather than asking you to keep a second copy in sync.
          This list is for everything else the SITE ITSELF might
          legitimately link to that isn't already implied by your own
          configuration (e.g. a companion domain the site embeds or
          links out to).
        '';
      };

      blockedSchemes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "webcal" ];
        description = ''
          URI schemes that should silently do nothing when navigated to
          -- no native "choose an application" dialog, no app launches.
          Confirmed live: a mailto: link produces exactly that dialog
          (offering e.g. Gmail or an arbitrary "Choose other
          Application" picker), as real a kiosk-escape route as an
          unrestricted http(s) link, just via a different mechanism --
          same reasoning as `allowedHosts` above, but these schemes
          need blocking unconditionally rather than allow-listed, since
          there's no legitimate reason a kiosk would ever want to hand
          off to a native app at all.

          This is a *stronger* protection than nav-guard.js's own click-
          time scheme check (which already treats any non-http(s)/non-
          javascript: scheme as disallowed) -- that only catches an
          actual link CLICK, same limitation `allowedHosts`' own
          redirect check exists to cover for http(s). This instead
          configures Firefox's Handlers policy directly, at the layer
          that resolves ANY navigation to one of these schemes (a
          click, a script-driven `location.href` change, a redirect --
          it doesn't matter how it was reached), to hand off to a real
          but inert default (this kiosk's own `url`) instead of asking
          -- confirmed live that Mozilla's own documented "no default
          handler" config (`ask=false` with an empty-object handler)
          does NOT actually suppress the dialog despite what the docs
          imply; only giving it a genuine handler to silently use does.
          The current tab's own location never actually changes when
          this fires (confirmed live), so this is a fail-safe target
          rather than something a visitor would ever actually see.

          `[ ]` here (the option's own declared default) is NOT what
          actually ships -- this module's own `config` separately
          contributes a comprehensive built-in list covering every
          commonly-encountered app-handoff scheme, which ordinary
          NixOS list-option merging unions with whatever you add here
          (two plain list definitions for the same option, from two
          different modules, concatenate rather than one replacing the
          other -- confirmed via an isolated evalModules test, not
          assumed). Add your own entries for anything a specific site
          links to that isn't already covered; use `allowedSchemes`
          below to remove one of the built-in ones instead (plain list
          subtraction can't express "minus this one item" the way
          addition can).

          Blocking every scheme by DEFAULT the way `allowedHosts`
          allow-LISTS hosts isn't possible here: Firefox's Handlers
          policy has no wildcard/catch-all entry, only explicitly named
          schemes, and there's no way to enumerate every URI scheme
          that might ever exist. The built-in list is deliberately
          broad to get as close to that as practically possible, but
          it's a known-schemes list, not a true default-deny.
        '';
      };

      allowedSchemes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "webcal" ];
        description = ''
          Schemes to exclude from `blockedSchemes`' final, effective
          list -- the only way to remove one of this module's own
          built-in blocked schemes (or one you added yourself from
          another module) without needing to know or repeat the whole
          rest of that list, since plain NixOS list options only ever
          concatenate, never subtract.
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
      defaultText = lib.literalExpression ''
        {
          uBlockOrigin = { id = "uBlock0@raymondhill.net"; };
          consentOMatic = {
            id = "gdpr@cavi.au.dk";
            storageSyncSeed = { debugFlags.autoOpenOptionsTab = false; };
          };
          autoscrollShorts = { id = "{96d7f719-11f8-427d-898f-51b4a3803952}"; enable = false; };
        }
      '';
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

    permissions = {
      camera = mkPermissionOption "Camera";
      microphone = mkPermissionOption "Microphone";
      location = mkPermissionOption "Location";
      notifications = mkPermissionOption "Notifications";
      virtualReality = mkPermissionOption "VirtualReality";
      screenShare = mkPermissionOption "ScreenShare";
      autoplay = autoplayPermission;
      storageAccess = storageAccessPermission;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.idleTimeoutMinutes == 0 || cfg.touch != null;
        message = "services.kiosk-mode.idleTimeoutMinutes > 0 requires services.kiosk-mode.touch to be set -- nothing to watch for activity otherwise";
      }
    ];

    # The built-in blockedSchemes list -- see that option's own
    # description for why this lives here (a plain assignment, not the
    # option's declaration-level `default`) rather than being the thing
    # that shows up as its literalExample/documented default: a plain
    # list assignment from THIS module and a plain list assignment from
    # a caller's own module concatenate (confirmed via an isolated
    # evalModules test), where the option's declaration-level `default`
    # would instead just get discarded outright the moment a caller
    # defines the option at all -- the same "does this merge or does it
    # replace" distinction `extensions`/`navigation.buttons` already
    # document for the attrsOf-submodule case, just the listOf version
    # of it.
    #
    # Deliberately broad, not exhaustive -- Firefox's Handlers policy
    # has no wildcard entry, only named schemes, so "block everything"
    # isn't achievable here the way `allowedHosts` allow-lists hosts;
    # this is this module's best attempt at covering the schemes real
    # web content is actually likely to link to for external-app
    # handoff. mailto/tel/sms are confirmed live (see blockedSchemes'
    # own description); the rest are well-known scheme names, not
    # independently verified against a real triggering site the way
    # those three are.
    services.kiosk-mode.navigation.blockedSchemes = [
      "mailto"
      "tel"
      "sms"
      "smsto"
      "callto"
      "skype"
      "whatsapp"
      "webcal"
      "magnet"
      "irc"
      "ircs"
      "xmpp"
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

    services.udev.extraRules = lib.concatStringsSep "\n" (
      lib.optional (cfg.touch != null) ''
        SUBSYSTEM=="input", ATTRS{idVendor}=="${cfg.touch.vendorId}", ATTRS{idProduct}=="${cfg.touch.productId}", ENV{LIBINPUT_CALIBRATION_MATRIX}="${cfg.touch.calibrationMatrix.${cfg.screenRotation}}"
        SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="${cfg.touch.vendorId}", ATTRS{idProduct}=="${cfg.touch.productId}", SYMLINK+="input/kiosk-touch"
      ''
      ++ lib.optional (cfg.camera != null) ''
        # The real camera: matched by vendor/product ID (like touch above)
        # rather than relying on udev's own stock /dev/v4l/by-id rules,
        # since those need a USB serial number to generate a stable
        # symlink and not every camera reports one. ID_V4L_CAPABILITIES
        # excludes a UVC camera's separate metadata-only device node
        # (present alongside the actual capture node on newer UVC
        # cameras, confirmed live: it reports ID_V4L_CAPABILITIES=":"
        # with no "capture", vs. ":capture:" on the real one) -- without
        # this, the rule would also match and symlink the metadata node,
        # racing with the real one for the same symlink target.
        SUBSYSTEM=="video4linux", ATTRS{idVendor}=="${cfg.camera.vendorId}", ATTRS{idProduct}=="${cfg.camera.productId}", ENV{ID_V4L_CAPABILITIES}=="*:capture:*", SYMLINK+="video/kiosk-camera-real"
        # The virtual v4l2loopback device: matched by its own card_label
        # (set in boot.extraModprobeConfig below and surfaced by udev as
        # ID_V4L_PRODUCT), not vendor/product ID -- it's not a real USB
        # device, so those don't apply.
        SUBSYSTEM=="video4linux", ENV{ID_V4L_PRODUCT}=="kiosk-camera-follow-rotation", SYMLINK+="video-follow-rotation"
      ''
    );

    boot.kernelModules = lib.mkIf (cfg.camera != null) [ "v4l2loopback" ];
    boot.extraModulePackages = lib.mkIf (cfg.camera != null) [ config.boot.kernelPackages.v4l2loopback ];
    boot.extraModprobeConfig = lib.mkIf (cfg.camera != null) ''
      # exclusive_caps=1: without it, a v4l2loopback device advertises
      # BOTH capture and output capabilities on the same node, which is
      # the historically-correct V4L2 model but not what most consumer
      # apps (browsers among them) expect from a device they enumerate
      # for getUserMedia()/camera use -- this is v4l2loopback's own
      # documented fix for that specific compatibility gap, not a value
      # picked at random. No explicit video_nr: letting the kernel
      # assign one dynamically avoids fighting the real camera (or any
      # other future video4linux device) for a specific number, since
      # this module identifies the loopback device by its card_label via
      # udev (see services.udev.extraRules above) rather than by index.
      options v4l2loopback card_label="kiosk-camera-follow-rotation" exclusive_caps=1
    '';

    # Relay service: reads the real camera (via its own stable
    # vendor/product-matched symlink, not a raw /dev/videoN index that
    # could shift once v4l2loopback claims a device number too) and
    # writes rotation-corrected frames into the v4l2loopback device,
    # which appears at /dev/video-follow-rotation via the udev rule
    # above. Restart=always + StartLimitIntervalSec=0 for the same
    # reason as kiosk-idle-reset.service elsewhere in this module: a
    # camera that's briefly unplugged/re-enumerated shouldn't be able to
    # trip systemd's default restart-rate limit and give up permanently.
    systemd.services.kiosk-camera-follow-rotation = lib.mkIf (cfg.camera != null) {
      description = "Relay the real camera into /dev/video-follow-rotation, rotated to match screenRotation";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = "2s";
        ExecStart = pkgs.writeShellScript "kiosk-camera-follow-rotation" ''
          set -eu
          # Both symlinks are created by udev rules triggered off device
          # events this service's own unit ordering (after
          # systemd-udev-settle.service) should already guarantee have
          # settled -- this loop is just defense against the specific
          # case of the real camera being plugged in/re-enumerating
          # after that point, not the expected common case.
          for _ in $(seq 1 30); do
            [ -e /dev/video/kiosk-camera-real ] && [ -e /dev/video-follow-rotation ] && break
            sleep 1
          done
          exec ${lib.getExe pkgs.ffmpeg} ${
            lib.escapeShellArgs (
              [
                "-hide_banner"
                "-loglevel"
                "error"
                "-f"
                "v4l2"
                "-input_format"
                cfg.camera.inputFormat
              ]
              ++ lib.optionals (cfg.camera.videoSize != null) [
                "-video_size"
                cfg.camera.videoSize
              ]
              ++ lib.optionals (cfg.camera.framerate != null) [
                "-framerate"
                (toString cfg.camera.framerate)
              ]
              ++ [
                "-i"
                "/dev/video/kiosk-camera-real"
                # ",format=yuv420p" is load-bearing, not cosmetic: an
                # MJPEG source decodes to a JPEG-range pixel format
                # (yuvj420p/yuvj422p) that has no direct V4L2 fourcc
                # equivalent, so writing straight to the v4l2 muxer
                # fails outright ("Unknown V4L2 pixel format equivalent
                # for yuvj422p" / "Could not write header (incorrect
                # codec parameters?)", confirmed live). Forcing a real
                # V4L2-mappable format after the rotation filter fixes
                # it regardless of what the decoder produces natively.
                "-vf"
                "${cfg.camera.rotationFilter.${cfg.screenRotation}},format=yuv420p"
                "-f"
                "v4l2"
                "/dev/video-follow-rotation"
              ]
            )
          }
        '';
      };
    };

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
        (lib.mkIf (permissionsPolicy != { }) { Permissions = permissionsPolicy; })
        (lib.mkIf (storageAccessPolicy != { }) storageAccessPolicy)
        (lib.mkIf (blockedSchemesPolicy != { }) blockedSchemesPolicy)
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
        KIOSK_PRIVATE_BROWSING = if cfg.privateBrowsing then "true" else "false";
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

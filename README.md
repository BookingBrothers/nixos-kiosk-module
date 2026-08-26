# nixos-kiosk-mode

A NixOS module providing `services.kiosk-mode`: a single-purpose
touchscreen/display kiosk. [cage](https://github.com/cage-kiosk/cage) (a
Wayland compositor for exactly one fullscreen client) runs Firefox pinned to
one URL, with the browser profile wiped and rebuilt from scratch on every
restart so the kiosk never accumulates history/cache/session state across
restarts or reboots.

## Usage

This is a plain NixOS module. It works identically with or without flakes --
`flake.nix` is a thin wrapper around `default.nix`, not a second copy.

### With flakes

```nix
{
  inputs.nixos-kiosk-mode.url = "github:BookingBrothers/nixos-kiosk-module";

  outputs = { self, nixpkgs, nixos-kiosk-mode, ... }: {
    nixosConfigurations.mykiosk = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-kiosk-mode.nixosModules.default
        {
          services.kiosk-mode = {
            enable = true;
            url = "https://example.com/";
          };
        }
      ];
    };
  };
}
```

### Without flakes

Vendor a copy (git submodule, `fetchTarball`, `niv`, whatever you already use
for external NixOS modules) and import it directly:

```nix
{
  imports = [ /path/to/nixos-kiosk-mode ];

  services.kiosk-mode = {
    enable = true;
    url = "https://example.com/";
  };
}
```

## Options

All options live under `services.kiosk-mode`. The only one you must set is
`url`; everything else has a sensible default (`extensions` ships three
built-in entries -- see [Extensions](#extensions) below).

**Full reference: [`docs/options.md`](docs/options.md)** -- generated from
the doc comments in `default.nix`. Do not edit it by hand; after changing
an option's type/default/description, run `nix run .#gen-docs` and commit
the result -- `nix flake check` (`checks.docs-up-to-date`, wired into CI)
fails if you forget.

### Extensions

`services.kiosk-mode.extensions` is a real, user-extensible API (an
`attrsOf submodule`, the same shape nixpkgs uses for e.g.
`systemd.services.<name>`) -- `uBlockOrigin`/`consentOMatic`/
`autoscrollShorts` are its own built-in entries, not special-cased code, so
add your own the exact same way:

```nix
services.kiosk-mode.extensions.myAdBlocker.id = "...@example.com";
```

and turn a built-in one off the same way any entry overrides another:

```nix
services.kiosk-mode.extensions.uBlockOrigin.enable = false;
```

See `docs/options.md` (`services.kiosk-mode.extensions.<name>.*`) for every
field a single entry accepts (`installationMode`, `installUrl`, `xpi`,
`privateBrowsing`, `storageSyncSeed`, `settings`).

## Known limitations

- Neither `mode` value blocks Ctrl+L/T/N/S/U from reaching Firefox's own
  keybindings -- a real, open gap, not yet fixed.
- `navigation.blockedSchemes` is a known-schemes list (comprehensive,
  not exhaustive), not a true default-deny -- Firefox's Handlers policy
  has no wildcard/catch-all entry, only explicitly named schemes, so an
  unlisted scheme this module doesn't know about still falls through to
  Firefox's native "choose an application" dialog. `allowedHosts`
  reaches actual default-deny for http(s) hosts specifically because
  that check runs in JS, which can generically distinguish "http(s)"
  from "everything else" without needing to name every non-http(s)
  scheme in existence.
- `permissions.storageAccess` (blocking the Storage Access API's own
  "<site> wants to use cookies from <other site>..." prompt) is NOT
  confirmed live to actually suppress that dialog, unlike this module's
  other `permissions.*` entries -- Mozilla's docs don't spell out the
  exact relationship between the `Cookies` policy and this specific
  prompt the way they do for `Permissions.<Type>.BlockNewRequests`.
- `touch.calibrationMatrix`, `devPixelsPerPx`, and `camera.rotationFilter`
  are physically/visually tuned per device and per site; this module
  deliberately doesn't try to derive them, it just takes the already-
  resolved values.
- `camera` relays the real camera into a second, rotation-corrected
  device (`/dev/video-follow-rotation`) rather than replacing the real
  one -- existing page content/scripts that already open the camera
  directly are unaffected, and have to be pointed at the new path
  explicitly to get the rotated feed.
- Extension IDs/behavior for the three built-in `extensions` entries
  (`uBlockOrigin`, `consentOMatic`, `autoscrollShorts`) were verified
  against real, currently-published extensions at the time this module
  was written, not guessed. Extension behavior around AMO installation
  and storage has changed before (see the `installUrl` and
  `storageSyncSeedDb` comments in `default.nix`) and may change again --
  if a built-in entry stops working after a Firefox or extension update,
  those comments are the place to start.

## Repository layout

```
default.nix                    the module (options + config)
flake.nix                      thin flake wrapper around default.nix, plus docs generation
scripts/                       shell scripts run by the module's systemd units
kiosk-keyboard-extension/      the force-installed on-screen-keyboard/nav-lock extension
docs/options.md                generated option reference -- `nix run .#gen-docs` to refresh
.github/workflows/checks.yml   runs `nix flake check` (incl. docs-up-to-date) on push/PR
```

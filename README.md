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
`url`; everything else has a sensible default. Run
`nix eval .#nixosConfigurations.<name>.options.services.kiosk-mode` (or just
read `default.nix` -- it's one file) for the full, current list with
descriptions; the shape is:

| Option | Type | Default | What it's for |
|---|---|---|---|
| `enable` | bool | `false` | Turn the whole thing on. |
| `user` | string | `"kiosk"` | Local user cage/Firefox run as. Created by this module. |
| `url` | string | *(required)* | The URL to show, and what the kiosk resets back to. |
| `mode` | `"custom"` \| `"builtin"` | `"custom"` | Which Firefox kiosk mechanism to use -- see the option's own doc comment for the tradeoff. |
| `screenRotation` | `"normal"` \| `"left"` \| `"right"` \| `"inverted"` | `"normal"` | Output rotation, applied via `wlr-randr`. |
| `devPixelsPerPx` | string | `"1"` | `layout.css.devPixelsPerPx`, for bigger touch targets. |
| `idleTimeoutMinutes` | int | `0` | Minutes of no touch before auto-resetting back to `url`. Requires `touch`. |
| `touch` | submodule or `null` | `null` | Touchscreen calibration (`vendorId`, `productId`, `calibrationMatrix`) and a stable `/dev/input/kiosk-touch` symlink. |
| `navigation.onScreenKeyboard.enable` | bool | `false` | Force-install a touch on-screen keyboard extension. |
| `navigation.backButton.enable` | bool | `false` | Floating back button. |
| `navigation.homeButton.enable` | bool | `false` | Floating home button (→ `url`). |
| `navigation.allowedHosts` | list of string or `null` | `null` | Block link clicks to any hostname not in this list (or a subdomain of one). |
| `audio.enable` | bool | `false` | PipeWire audio for the kiosk session. |
| `allowVtSwitch` | bool | `false` | Allow Ctrl+Alt+Fn VT switching (off by default -- read the option doc before turning this on for a public-facing kiosk). |
| `extraGroups` | list of string | `[ ]` | Extra groups for the kiosk user (e.g. `"video"` for a USB webcam). |
| `extensions.uBlockOrigin.enable` | bool | `true` | Force-install uBlock Origin. |
| `extensions.consentOMatic.enable` | bool | `true` | Force-install Consent-O-Matic (auto-answers GDPR cookie banners). |
| `extensions.autoscrollShorts.enable` | bool | `false` | Force-install an extension that auto-advances YouTube Shorts. |

## Known limitations

- Neither `mode` value blocks Ctrl+L/T/N/S/U from reaching Firefox's own
  keybindings -- a real, open gap, not yet fixed.
- `touch.calibrationMatrix` and `devPixelsPerPx` are physically/visually
  tuned per device and per site; this module deliberately doesn't try to
  derive them, it just takes the already-resolved values.
- Extension IDs/behavior (`uBlockOrigin`, `consentOMatic`, `autoscrollShorts`)
  were verified against specific Firefox and extension versions at the time
  this module was written (Firefox ~154, uBlock Origin, Consent-O-Matic
  1.1.5, "Autoscroll Shorts" 1.6). Extension behavior around AMO installation
  and storage has changed before (see the `install_url` and
  `consentOMaticSyncSeedDb` comments in `default.nix`) and may change again.

## Repository layout

```
default.nix                    the module (options + config)
flake.nix                      thin flake wrapper around default.nix
scripts/                       shell scripts run by the module's systemd units
kiosk-keyboard-extension/      the force-installed on-screen-keyboard/nav-lock extension
```

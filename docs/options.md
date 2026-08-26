## services\.kiosk-mode\.enable



Whether to enable a single-purpose touchscreen/display kiosk (cage + Firefox pinned to one URL)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.allowVtSwitch

cage’s ` -s ` flag (allow Ctrl+Alt+Fn VT switching, which cage
disables by default)\. Off by default\. Turning this on re-enables
console access at the physical device straight to a getty login
prompt on another VT – consider what accounts exist and what
they can do before enabling this on a public-facing kiosk\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.audio\.enable



Whether to enable PipeWire audio for the kiosk session (off by default – only worth it if the site actually plays sound and the hardware has a real output route)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.devPixelsPerPx



layout\.css\.devPixelsPerPx: makes touch targets bigger by shrinking
the *effective CSS viewport* (physical px / this value = CSS px)\.
The right value is rotation- and site-dependent – this module
doesn’t try to compute one, it’s a plain passthrough\.



*Type:*
string



*Default:*

```nix
"1"
```



*Example:*

```nix
"2.5"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions



Firefox extensions to install into the kiosk profile, keyed by an
arbitrary short Nix-level name\. ` uBlockOrigin `/` consentOMatic `/
` autoscrollShorts ` ship built in (set via ` lib.mkDefault ` in this
module’s own ` config `, not special-cased elsewhere) – turn any
of them off the same way you’d override any other default:
` services.kiosk-mode.extensions.uBlockOrigin.enable = false; `\.
Add your own the same way:

```nix
services.kiosk-mode.extensions.myAdBlocker.id = "...@example.com";
```

uBlock Origin is on by default: worth having on any kiosk
rendering real third-party web content\. Consent-O-Matic is on by
default too (auto-answers GDPR cookie-consent dialogs): a kiosk
nobody is standing at to click “Accept” through a modal cookie
banner needs it handled automatically\. “Autoscroll Shorts” (auto-
advances to the next
YouTube Short when the current one ends) is off by default –
unlike the other two, it’s only useful on a kiosk that actually
shows YouTube Shorts; picked over several similar extensions
specifically because it has no storage/settings/toggle at all
(verified by reading its full content script), so there’s nothing
to fight against this module’s wipe-every-restart profile, unlike
alternatives that either default off or reopen their own install
tab every restart via a storage\.local flag (much harder to
pre-seed than storage\.sync – see ` storageSyncSeed `’s own
description for why storage\.sync is already the harder case)\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.enable



Whether to install this extension\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.id



The extension’s real Firefox/gecko extension ID
(browser_specific_settings\.gecko\.id in its manifest\.json) –
what Firefox’s ExtensionSettings policy actually keys on\. The
attribute name (` ‹name› `) is only a Nix-level handle for
overriding this one entry from your own configuration\.



*Type:*
string



*Example:*

```nix
"uBlock0@raymondhill.net"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.installUrl



Where Firefox fetches this extension from\. Leave null for an
AMO-hosted extension – as of Firefox 153, install_url is
optional for those; Firefox resolves and installs the latest
version straight from AMO by ` id ` alone\. Confirmed live that
the explicit install_url form
(addons\.mozilla\.org/…/latest\.xpi) silently failed to
trigger an install at all on a current Firefox devedition
build despite working network access to AMO – prefer
leaving this null unless you have a specific reason not to
(e\.g\. a non-AMO-hosted xpi URL)\.

Ignored when ` xpi ` is set – that always installs via a
local file:// URL instead\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.installationMode



Firefox’s ExtensionSettings ` installation_mode ` – see
Mozilla’s enterprise policy documentation\.
“normal_installed” ships pre-installed and enabled but stays
a regular extension the user can disable/remove via
about:addons; “force_installed” cannot be removed\.



*Type:*
one of “allowed”, “blocked”, “force_installed”, “normal_installed”



*Default:*

```nix
"normal_installed"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.privateBrowsing



Whether this extension is allowed to run in a private-
browsing window\. This module forces permanent private
browsing (browser\.privatebrowsing\.autostart), and Firefox
disables extensions inside private windows by default –
almost every extension needs this true to do anything at
all, which is why it defaults to true here rather than
false\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.settings



Extra keys merged directly into this extension’s ExtensionSettings entry, verbatim\.



*Type:*
attribute set of anything



*Default:*

```nix
{ }
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.storageSyncSeed



Data to pre-seed into this extension’s browser\.storage\.sync
before Firefox first starts, for an extension that gates
first-run behavior (e\.g\. an onboarding tab) on a flag that
would otherwise reset to its default every single restart\.
Merged with every other extension’s own seed (if any) into
one shared database – see this module’s own
` storageSyncSeedDb ` for why that has to be shared rather than
per-extension, and its own PRAGMA user_version comment for a
correctness gotcha worth reading before relying on this for
a new extension\.



*Type:*
null or (attribute set of anything)



*Default:*

```nix
null
```



*Example:*

```nix
{
  debugFlags = {
    autoOpenOptionsTab = false;
  };
}
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extensions\.\<name>\.xpi



A locally-built xpi (e\.g\. an extension you author yourself,
like this module’s own on-screen keyboard) to force-install
via a file:// URL, instead of fetching one from ` installUrl `\.
Setting this on ANY extension switches the whole profile to
firefox-devedition and unlocks xpinstall\.signatures\.required
– plain Firefox hard-enforces AMO signature checks with no
override, and devedition is the one nixpkgs Firefox variant
that doesn’t\.



*Type:*
null or package



*Default:*

```nix
null
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.extraGroups



Extra groups for the kiosk user beyond the default none – e\.g\. ` video ` on a host with a USB webcam Firefox needs to open\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "video"
]
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.idleTimeoutMinutes



Minutes of no touch activity before the kiosk restarts itself back
to ` url ` (a systemd timer + a raw-input-reading watchdog –
deliberately NOT a JS page timer, since a hung tab or a page that
stops-propagation on input events could silently disable one of
those)\. 0 disables idle-reset entirely\. Requires ` touch ` to be
set – nothing to watch for activity otherwise\.

Repeats for as long as the kiosk stays genuinely idle, not just
once: the reset re-arms its own timer right after firing, so an
untouched kiosk keeps resetting every ` idleTimeoutMinutes `
indefinitely\. A real touch still extends the deadline immediately
either way\.



*Type:*
unsigned integer, meaning >=0



*Default:*

```nix
0
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.mode



“custom”: launches Firefox with ` --private-window `, browser chrome
hidden via userChrome\.css (scripts/firefox-kiosk\.sh)\.
“builtin”: launches with Firefox’s own ` --kiosk ` flag instead\.

Neither value blocks Ctrl+L/T/N/S/U from reaching Firefox’s own
keybindings – a known open gap in both modes, not yet fixed\.
Permanent private browsing (browser\.privatebrowsing\.autostart)
is forced unconditionally either way, regardless of this setting\.



*Type:*
one of “custom”, “builtin”



*Default:*

```nix
"custom"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.navigation\.allowedHosts



A list of hostnames, or null to disable\. When set, blocks
clicking any link to a hostname NOT in the list (or a subdomain
of one) – a direct kiosk-escape route needing no keyboard
trick at all (e\.g\. an embedded video’s own “watch on the
original site” button, or a mailto: link opening a native
“choose an application” dialog)\. Doesn’t touch legitimately
embedded third-party content (iframes) – only intercepts a
visitor actually clicking through to leave the site\. A list
rather than one hostname since a site can legitimately span
more than one domain (e\.g\. a short-link domain alongside the
main one, or a companion platform it links out to)\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "example.com"
  "example.org"
]
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.navigation\.backButton\.enable



Whether to enable a small floating back button (history\.back()), top-left corner –
independent of onScreenKeyboard, since a kiosk can have subpages
to navigate back out of without needing text input at all
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.navigation\.homeButton\.enable



Whether to enable a small floating home button (navigates to ` url `), alongside the
back button in the same top-left corner
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.navigation\.onScreenKeyboard\.enable



Whether to enable a touch on-screen keyboard, force-installed as a browser extension
(layout follows the page’s declared language, falling back to
plain QWERTY for anything not explicitly covered – see
kiosk-keyboard-extension/content\.js)\. Off by default: most
dashboards (e\.g\. a read-only display) have nothing to type into
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.screenRotation



Applied via wlr-randr (xrandr-style naming) against the live compositor\.



*Type:*
one of “normal”, “left”, “right”, “inverted”



*Default:*

```nix
"normal"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.touch



Touchscreen calibration and a stable /dev/input/kiosk-touch udev
symlink\. null (the default) means no touchscreen – e\.g\. a fixed
display panel with no touch input at all\.

Rotating the *output* (` screenRotation `) doesn’t rotate *touch
input* – most digitizers report raw physical coordinates
regardless of how the display is rotated, so libinput needs an
explicit calibration matrix or touches land offset from what’s on
screen\. cage has no per-compositor config for this, so it’s done
at the udev/libinput layer instead, which is compositor-
independent anyway\. These values are physically measured against
one specific piece of hardware – there’s no way to derive them
generically, so this module takes the already-resolved matrix
string rather than trying to compute one\.



*Type:*
null or (submodule)



*Default:*

```nix
null
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.touch\.calibrationMatrix



The final, already-resolved-for-the-current-rotation
LIBINPUT_CALIBRATION_MATRIX string (same X\.Org Coordinate
Transformation Matrix convention libinput uses)\.



*Type:*
string



*Example:*

```nix
"1 0 0 0 1 0"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.touch\.productId



Matched against ATTRS{idProduct} (services\.udev\.extraRules)\.



*Type:*
string



*Example:*

```nix
"5678"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.touch\.vendorId



Matched against ATTRS{idVendor} (services\.udev\.extraRules)\.



*Type:*
string



*Example:*

```nix
"1234"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.url



The URL to show, and what the kiosk resets back to on restart/idle-timeout\.



*Type:*
string



*Example:*

```nix
"https://example.com/"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



## services\.kiosk-mode\.user



Local user cage/Firefox run as\. Created by this module\.



*Type:*
string



*Default:*

```nix
"kiosk"
```

*Declared by:*
 - [default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)



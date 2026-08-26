{
  description = "services.kiosk-mode: a single-purpose touchscreen/display kiosk (cage + Firefox pinned to one URL)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, ... }: {
    # `default.nix` at the repo root IS the module -- this just exposes
    # the same file under the flake outputs a consumer expects, so
    # there is exactly one copy of the module to keep in sync, not two.
    nixosModules.default = import ./default.nix;
    nixosModules.kiosk-mode = self.nixosModules.default;
  };
}

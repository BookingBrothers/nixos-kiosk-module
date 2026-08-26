{
  description = "services.kiosk-mode: a single-purpose touchscreen/display kiosk (cage + Firefox pinned to one URL)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # A full nixosSystem, not a bare `lib.evalModules [ ./default.nix ]`
      # -- this module's own `config` block sets options (systemd.services,
      # services.udev, programs.firefox, ...) that only exist once the
      # rest of nixpkgs' NixOS modules are imported too, which a real
      # nixosSystem does automatically and a bare evalModules doesn't.
      # nixosOptionsDoc only introspects .options (types/defaults/
      # descriptions), never forces .config, so the fixesystems/
      # bootloader stubs below only exist to satisfy nixosSystem's own
      # unrelated assertions, not this module's.
      docsSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          {
            system.stateVersion = "25.05";
            fileSystems."/" = {
              device = "/dev/sda1";
              fsType = "ext4";
            };
            boot.loader.grub.device = "nodev";
          }
        ];
      };

      optionsDoc = pkgs.nixosOptionsDoc {
        options = docsSystem.options.services.kiosk-mode;
      };

      # nixosOptionsDoc's `transformOptions` can rewrite `declarations`
      # entries, but nixos-render-docs' OWN rendering step (a separate
      # tool `optionsCommonMark` shells out to) unconditionally treats
      # anything that isn't an absolute path as nixpkgs-relative and
      # prepends its own hardcoded github.com/NixOS/nixpkgs/blob/<rev>/ --
      # there's no override for a third-party module's own repo (tried
      # transformOptions first; it just made nixos-render-docs wrap an
      # already-complete URL in ANOTHER one). Every option in this module
      # lives in exactly one file, so its rendered "Declared by" line is
      # identical -- confirmed live -- across all of them; substituting
      # that one known (store-path-parameterized, hence the regex rather
      # than a literal string) line for a real link after the fact is
      # simpler and more robust than fighting the tool's own opinion.
      finalOptionsDoc =
        pkgs.runCommand "kiosk-mode-options.md" { nativeBuildInputs = [ pkgs.gnused ]; }
          ''
            sed -E 's#\[/nix/store/[a-z0-9]+-source/default\\\.nix\]\(file:///nix/store/[a-z0-9]+-source/default\.nix\)#[default.nix](https://github.com/BookingBrothers/nixos-kiosk-module/blob/main/default.nix)#' \
              ${optionsDoc.optionsCommonMark} > $out
          '';
    in
    {
      # `default.nix` at the repo root IS the module -- this just exposes
      # the same file under the flake outputs a consumer expects, so
      # there is exactly one copy of the module to keep in sync, not two.
      #
      # The bare PATH, not `import ./default.nix` -- the module system
      # imports path-valued module list entries itself, which is what
      # gives it correct `_file` tracking for "declared by" (used in
      # generated docs/options.md below). An already-evaluated function
      # value (what eager `import` produces) loses that: every option
      # ends up attributed to wherever the module LIST is constructed
      # (this file) instead of where it's actually declared
      # (default.nix) -- confirmed live via gen-docs before this fix.
      nixosModules.default = ./default.nix;
      nixosModules.kiosk-mode = self.nixosModules.default;

      packages.${system}.optionsDoc = finalOptionsDoc;

      # `nix run .#gen-docs` regenerates docs/options.md from the module's
      # own option declarations -- run this after changing an option's
      # type/default/description.
      apps.${system}.gen-docs = {
        type = "app";
        meta.description = "Regenerate docs/options.md from services.kiosk-mode's own option declarations";
        program = "${pkgs.writeShellScript "gen-docs" ''
          set -eu
          cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
          install -m644 ${finalOptionsDoc} docs/options.md
          echo "wrote docs/options.md"
        ''}";
      };

      # CI-checkable: fails if docs/options.md doesn't match what
      # `nix run .#gen-docs` would currently produce, i.e. someone changed
      # an option without regenerating the docs.
      checks.${system}.docs-up-to-date = pkgs.runCommand "kiosk-mode-docs-up-to-date" { } ''
        diff -u ${./docs/options.md} ${finalOptionsDoc} \
          || { echo "docs/options.md is out of date -- run 'nix run .#gen-docs' and commit the result" >&2; exit 1; }
        touch $out
      '';
    };
}

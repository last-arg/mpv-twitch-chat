{
  description = "my project description";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";

    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  outputs = { self, nixpkgs, flake-utils }@inputs:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          zig-master = final: prev:
            {
              zig-master = final.zig.overrideAttrs (oldAttrs: rec {
                rev = "91e3431d4a55aa46884b267be5aa586f3ed94f74";
                version = builtins.substring 0 6 rev;
                src = final.fetchFromGitHub {
                  owner = "ziglang";
                  repo = oldAttrs.pname;
                  rev = rev;
                  sha256 = "0bj1ch5yxyafwzsh8vaqfi1wc7i1bfd32wbib8vys85f17h1lyar";
                };
                doCheck = false;
              });
            };
          pkgs' = import nixpkgs { inherit system; overlays = [ zig-master ]; };
          notcurses = pkgs'.callPackage ./nix/notcurses.nix { };
          dev_shell = pkgs'.mkShell
            {
              buildInputs = [
                pkgs'.zig-master
                pkgs'.openssl
                pkgs'.pkgconfig
                notcurses
              ];
            };
        in
        {
          # devShell = import ./shell.nix { inherit pkgs; };
          devShell = dev_shell;
        }
      );
}

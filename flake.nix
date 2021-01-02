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
                version = "2021-01-02";
                src = final.fetchFromGitHub {
                  owner = "ziglang";
                  repo = oldAttrs.pname;
                  rev = "a9c75a2b48f202d5c55097877499942ed07cc2e8";
                  sha256 = "06k92fiid7i477v242flpc2vd2zmri7qi79msfav3ykivprpzg7w";
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

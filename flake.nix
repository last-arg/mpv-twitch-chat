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
                rev = "2b3b355a23bea47aacbdfd56b853abc83e2f3ed6";
                version = builtins.substring 0 6 rev;
                src = final.fetchFromGitHub {
                  owner = "ziglang";
                  repo = oldAttrs.pname;
                  rev = rev;
                  sha256 = "03xqvq0r0r0rrdm6qp4mlym5mz0b1vdlhx5z4hfw8yg72rff8wih";
                };
                doCheck = false;
              });
            };
          pkgs' = (import nixpkgs { inherit system; overlays = [ zig-master ]; });
          zig-binary = pkgs'.callPackage ./nix/zig-binary.nix { };
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

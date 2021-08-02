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
          zig-binary = final: prev: {
            zig-binary = prev.callPackage ./nix/zig-binary.nix { };
          };
          pkgs = (import nixpkgs { inherit system; overlays = [ zig-binary ]; });
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

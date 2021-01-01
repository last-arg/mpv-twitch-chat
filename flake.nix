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
          pkgs =
            let
              p = nixpkgs.legacyPackages.${system};
              zig-master = p.callPackage ./nix/zig.nix { };
              notcurses = p.callPackage ./nix/notcurses.nix { };
            in
            p // { inherit zig-master notcurses; };
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

{
  description = "my project description";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  # TODO: figure out how to add user defined packages - zig-master
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

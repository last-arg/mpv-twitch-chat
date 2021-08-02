{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig-binary
    # zig-master
    # zig
    openssl
    pkgconfig
    # wait till notcurses is in nixos-unstable (nixpkgs)
    notcurses
  ];
}

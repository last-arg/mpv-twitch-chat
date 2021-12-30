{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig-binary
    pkgconfig
    notcurses
  ];
}

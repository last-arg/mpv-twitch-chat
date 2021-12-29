{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig-binary
    # zig-master
    # zig
    openssl
    pkgconfig
    notcurses
  ];
}

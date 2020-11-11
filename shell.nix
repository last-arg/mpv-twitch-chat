{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig-master
    openssl
    pkgconfig
  ];
}

{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    # zig-master
    zig
    openssl
    glibc
    pkgconfig
    # wait till notcurses is in nixos-unstable (nixpkgs)
    notcurses
  ];
  shellHook = ''
    LD_PRELOAD=${notcurses}/lib:${glibc}/lib
  '';
}

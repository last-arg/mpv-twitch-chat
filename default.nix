with import <nixpkgs> {}; {
  buoy = stdenv.mkDerivation rec {
    name = "twitch-vod-chat";
    hardeningDisable = [ "all" ];
    nativeBuildInputs = [ pkgconfig ];
    buildInputs = [
      zig-master
      openssl
      pkgconfig
    ];
  };
}

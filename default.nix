with import <nixpkgs> {}; {
  buoy = stdenv.mkDerivation rec {
    name = "twitch-vod-chat";
    hardeningDisable = [ "all" ];
    buildInputs = [
      zig-master
      openssl
    ];
  };
}

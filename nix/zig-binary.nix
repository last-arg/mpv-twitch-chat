{ stdenv, lib, fetchurl, zlib }:

stdenv.mkDerivation rec {
  version = "0.9.0-dev";
  name = "zig-binary";

  src = builtins.fetchurl {
    url = "https://ziglang.org/builds/zig-linux-x86_64-0.9.0-dev.718+b465037a6.tar.xz";
    sha256 = "d0d103212bae02ac4f5275c625bba9512d6a9dd0f59c76ae6f84692813ca8881";
  };

  nativeBuildInputs = [ zlib ];
  buildInputs = [ zlib ];

  sourceRoot = ".";

  unpackCmd = ''
    tar xfJ $src --strip-components=1
  '';

  buildPhase = ":";

  # installPhase = ''
  #   mkdir -p $out/bin
  #   cp -R ./* $out/
  #   ln -s $out/zig $out/bin/zig
  #   rm $out/LICENSE
  # '';

  installPhase = ''
    install -D zig "$out/bin/zig"
    install -D LICENSE "$out/share/licenses/zig/LICENSE"
    cp -r lib "$out"
    install -d "$out/share/doc"
    cp -r docs "$out/share/doc/zig"
  '';

  meta = with lib; {
    description = "Programming languaged designed for robustness, optimality, and clarity";
    homepage = https://ziglang.org/;
    license = licenses.mit;
    platforms = platforms.unix;
    maintainers = [ maintainers.andrewrk ];
  };
}

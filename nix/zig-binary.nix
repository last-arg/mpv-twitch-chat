{ stdenv, lib, fetchurl, zlib }:

stdenv.mkDerivation rec {
  version = "0.10.0-dev";
  name = "zig-binary";

  src = builtins.fetchurl {
    url = "https://ziglang.org/builds/zig-linux-x86_64-0.10.0-dev.91+be5130ec5.tar.xz";
    sha256 = "acf0180b7b0063192cf763d8560bf362f0efd5e48ab46925879debd8ad3e8133";
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

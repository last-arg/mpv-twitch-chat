{ stdenv, fetchurl }:

stdenv.mkDerivation rec {
  version = "master";
  name = "zig-master";

  src = fetchurl {
    url = "https://ziglang.org/builds/zig-linux-x86_64-0.6.0+342ba960f.tar.xz";
    sha256 = "c11f12594f49080adc90275c327009349c7312ea1cad1b29a060e608f7d5b5e6";
  };

  sourceRoot = ".";

  unpackCmd = ''
    tar xfJ $src --strip-components=1
  '';

  buildPhase = ":";

  installPhase = ''
    mkdir -p $out/bin
    cp -R ./* $out/
    ln -s $out/zig $out/bin/zig
    rm $out/LICENSE
  '';

  meta = with stdenv.lib; {
    description = "Programming languaged designed for robustness, optimality, and clarity";
    homepage = https://ziglang.org/;
    license = licenses.mit;
    platforms = platforms.unix;
    maintainers = [ maintainers.andrewrk ];
  };
}

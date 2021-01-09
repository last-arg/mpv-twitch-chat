{ stdenv, fetchurl }:
let
  json_file = builtins.fetchurl {
    url = "https://ziglang.org/download/index.json";
    # flake requires a sha256
    sha256 = "08b2ccfyax5c704lx9ikrzvgw87h4a5ywfr5c5h7bkvv54wr7lnd";
    # sha256 = stdenv.lib.fakeSha256;
  };
  json_content = builtins.readFile json_file;
  json = builtins.fromJSON json_content;
  latest = json.master.x86_64-linux;
in
stdenv.mkDerivation rec {
  version = json.master.version;
  name = "zig-binary";

  src = fetchurl {
    url = latest.tarball;
    sha256 = latest.shasum;
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

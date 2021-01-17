{ stdenv, fetchurl }:
let
  json_file = builtins.fetchurl {
    url = "https://ziglang.org/download/index.json";
    # flake requires a sha256
    sha256 = "1p1m5r2dff48rhbpidv4adp21mk9agbhg3sxqf326wjkchflh4gc";
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

{ stdenv
, cmake
, pkgconfig
, pandoc
, libunistring
, ncurses
, ffmpeg
, fetchFromGitHub
, lib
, multimediaSupport ? true
}:
let
  version = "2.1.3";
in
stdenv.mkDerivation {
  pname = "notcurses";
  inherit version;

  outputs = [ "out" "dev" ];

  nativeBuildInputs = [ cmake pkgconfig pandoc ];

  buildInputs = [ libunistring ncurses ]
    ++ lib.optional multimediaSupport ffmpeg;

  cmakeFlags =
    [ "-DUSE_QRCODEGEN=OFF" "-DCMAKE_INSTALL_INCLUDEDIR=include" "-DCMAKE_INSTALL_LIBDIR=lib" ]
    ++ lib.optional (!multimediaSupport) "-DUSE_MULTIMEDIA=none";

  src = fetchFromGitHub {
    owner = "dankamongmen";
    repo = "notcurses";
    rev = "v${version}";
    sha256 = "1gndsim0wg28z8sv2xrk7vgw20yfdy7axj50nwml8893i4gi7xqg";
  };

  meta = {
    description = "blingful TUIs and character graphics";

    longDescription = ''
      A library facilitating complex TUIs on modern terminal emulators,
      supporting vivid colors, multimedia, and Unicode to the maximum degree
      possible. Things can be done with Notcurses that simply can't be done
      with NCURSES.
      It is not a source-compatible X/Open Curses implementation, nor a
      replacement for NCURSES on existing systems.
    '';

    homepage = "https://github.com/dankamongmen/notcurses";

    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
    maintainers = with lib.maintainers; [ jb55 ];
  };
}

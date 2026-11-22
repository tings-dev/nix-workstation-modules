# PyCharm with the source configuration's Skiko runtime-library fix.
{ lib, pkgs }:
# nixpkgs ships lib/skiko-awt-runtime-all/libskiko-linux-x64.so unpatched --
# its RPATH still points at the build sandbox, so libGL, libX11, libfontconfig
# and libstdc++ all resolve to "not found". skiko swallows the load failure,
# then every Compose/Jewel panel in the IDE dies with UnsatisfiedLinkError.
# Hand the loader the four libraries autoPatchelfHook missed.
#
# The bundled share/applications/pycharm.desktop launches a bare "pycharm", so
# wrapping $out/bin covers launcher starts as well as the CLI and autostart.
# symlinkJoin drops meta, hence the explicit mainProgram for callers of lib.getExe.
pkgs.symlinkJoin {
  name = "pycharm-skiko-wrapped";
  paths = [ pkgs.jetbrains.pycharm ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  meta.mainProgram = "pycharm";
  postBuild = ''
    wrapProgram $out/bin/pycharm \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          pkgs.libGL
          pkgs.libx11
          pkgs.fontconfig
          pkgs.stdenv.cc.cc
        ]
      }
  '';
}

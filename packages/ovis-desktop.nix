{
  lib,
  fetchurl,
  appimageTools,
}:
let
  pname = "ovis-desktop";
  version = "0.5.9";
  src = fetchurl {
    url = "https://github.com/devswha/ovis/releases/download/v${version}/Ovis-linux-x64.AppImage";
    hash = "sha256:46503e7d41069dabc8ee3abbc0005cc319a9d78f47a65dfb5d6e8e0064b971a7";
  };
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;
  extraInstallCommands = ''
    install -Dm444 ${contents}/*.desktop $out/share/applications/ovis-desktop.desktop
    substituteInPlace $out/share/applications/ovis-desktop.desktop \
      --replace-fail 'Exec=AppRun' 'Exec=ovis-desktop'
    cp -r ${contents}/usr/share/icons $out/share/
  '';
  meta = {
    description = "Desktop client for Ovis coding agents";
    homepage = "https://github.com/devswha/ovis";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "ovis-desktop";
  };
}

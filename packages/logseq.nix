{
  lib,
  appimageTools,
  fetchurl,
  ...
}:

let
  version = "0.10.9";
  pname = "logseq";

  src = fetchurl {
    url = "https://github.com/logseq/logseq/releases/download/${version}/Logseq-linux-x64-${version}.AppImage";
    hash = "sha256-XROuY2RlKnGvK1VNvzauHuLJiveXVKrIYPppoz8fCmc=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };

in
appimageTools.wrapType1 {
  inherit pname version src;

  extraInstallCommands = ''
    mkdir -p $out/share/logseq $out/share/applications

    cp -a ${appimageContents}/{locales,resources} $out/share/logseq
    cp -a ${appimageContents}/Logseq.desktop $out/share/applications/logseq.desktop
    mkdir -p $out/share/pixmaps
    ln -s $out/share/logseq/resources/app/icons/logseq.png $out/share/pixmaps/logseq.png
    substituteInPlace $out/share/applications/logseq.desktop \
      --replace Exec=Logseq Exec=logseq \
      --replace Icon=Logseq Icon=logseq 
  '';

  meta = {
    description = "Logseq, open-source outliner for knowledge management and collaboration";
    homepage = "https://logseq.com/";
    downloadPage = "https://github.com/logseq/logseq/releases";
    license = lib.licenses.agpl3Plus;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    maintainers = with lib.maintainers; [ idk ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "logseq";
  };
}

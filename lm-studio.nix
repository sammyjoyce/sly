# LM Studio package for Nix
# Usage: nix-shell -p 'callPackage ./lm-studio.nix {}'

{
  lib,
  stdenv,
  fetchurl,
  appimageTools,
  makeWrapper,
}:

let
  pname = "lm-studio";
  version = "0.3.15"; # Update this to latest version

  src = fetchurl {
    url = "https://releases.lmstudio.ai/linux/x86/${version}/LM-Studio-${version}.AppImage";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # Replace with actual hash
  };

  appimageContents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    install -m 444 -D ${appimageContents}/lm-studio.desktop $out/share/applications/lm-studio.desktop
    install -m 444 -D ${appimageContents}/lm-studio.png $out/share/pixmaps/lm-studio.png
    substituteInPlace $out/share/applications/lm-studio.desktop \
      --replace 'Exec=AppRun' 'Exec=${pname}'
  '';

  meta = with lib; {
    description = "Discover, download, and run local LLMs";
    homepage = "https://lmstudio.ai/";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}

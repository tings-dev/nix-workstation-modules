# Craft application choices and package selection for Home Manager.
{
  inputs,
  lib,
  pkgs,
}:
let
  packagePkgs = inputs.nixpkgs-packages.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  cachedApps = [
    "photocraft"
    "lightcraft"
    "vectorcraft"
    "pdfcraft"
    "wordcraft"
    "gridcraft"
    "deckcraft"
    "cadcraft"
    "soundcraft"
  ];
  prebuiltApps = [
    "filmcraft"
    "designcraft"
    "effectcraft"
    "figcraft"
  ];
in
{
  appsOption = lib.mkOption {
    type = lib.types.listOf (lib.types.enum (cachedApps ++ prebuiltApps));
    default = cachedApps;
    example = [
      "photocraft"
      "filmcraft"
    ];
    description = ''
      Craft apps to install. Defaults to nine packages from nixpkgs-unstable,
      independently of the NixOS system channel. FilmCraft, DesignCraft, EffectCraft and
      FigCraft use pinned upstream binaries with NixOS runtime wrappers.
      An explicit list replaces the default selection.
    '';
  };

  packagesFor =
    apps:
    lib.concatMap (
      name:
      if builtins.elem name cachedApps then
        [ packagePkgs.${name} ]
      else
        let
          package = inputs.craft-prebuilt.packages.${pkgs.stdenv.hostPlatform.system}.${name};
        in
        # Upstream splits menu entries, icons and MIME metadata from the binaries.
        [
          package
          package.desktop
        ]
    ) (lib.unique apps);
}

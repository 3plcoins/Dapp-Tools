{ nixpkgs ? import <nixpkgs> {} }:
let
  inherit (nixpkgs) pkgs;
#  profiling = pkgs.haskellPackages.override {
#    overrides = self: super: {
#      mkDerivation = args: super.mkDerivation (args // {
#        enableLibraryProfiling = true;
#      });
#    };
#  };

  restless-git = import /home/mbrock/projects/restless-git;

  haskellPackages = pkgs.haskellPackages.override {
    overrides = (self: super: {
      ghc =
        super.ghc // { withPackages = super.ghc.withHoogle; };
      ghcWithPackages =
        self.ghc.withPackages;
      restless-git =
        with pkgs.haskell.lib;
          dontCheck (self.callPackage restless-git {});
    });
  };

  drv = pkgs.haskell.lib.addBuildTool (
    haskellPackages.callPackage (import ./default.nix) {}
  ) [pkgs.git];

in if pkgs.lib.inNixShell then drv.env else drv

{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem flake-utils.lib.defaultSystems (
      system:
      let
        inherit (nixpkgs) lib;
        legacyPackagesForTargetISA =
          isa:
          let
            pkgs = import nixpkgs {
              inherit system;
              config.rocmSupport = true;
              overlays = lib.optional (isa != null) (
                final: prev: {
                  rocmPackages_6 = prev.rocmPackages_6.overrideScope (
                    fs: ps: {
                      clr = ps.clr.override {
                        localGpuTargets = [ isa ];
                      };
                    }
                  );
                  rocmPackages = final.rocmPackages_6;
                }
              );
            };
          in
          {
            inherit (pkgs) llama-cpp;
            image = pkgs.callPackage (
              {
                dockerTools,
                llama-cpp,
                bash,
                coreutils,
                buildEnv,
              }:
              dockerTools.buildLayeredImage {
                name = "llama-cpp-image";
                contents = [
                  llama-cpp
                  bash
                  coreutils
                  dockerTools.usrBinEnv
                ];
              }
            ) { };
          };
      in
      {
        legacyPackages = (legacyPackagesForTargetISA null) // {
          gfx1030 = legacyPackagesForTargetISA "gfx1030";
          gfx1100 = legacyPackagesForTargetISA "gfx1100";
          gfx1200 = legacyPackagesForTargetISA "gfx1200";
        };
      }
    );
}

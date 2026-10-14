{
  inputs = {
    common.url = "github:nammayatri/common?ref=ghc-98-upgrade";
    nixpkgs.follows = "common/nixpkgs";
    flake-parts.follows = "common/flake-parts";
    haskell-flake.follows = "common/haskell-flake";

    system.url = "github:nix-systems/default";
    services-flake.url = "github:juspay/services-flake";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  };
  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.system;
      imports = [
        inputs.common.flakeModules.ghc98
        inputs.haskell-flake.flakeModule
        inputs.process-compose-flake.flakeModule
      ];
      perSystem = { self', pkgs, config, ... }: {

        formatter = pkgs.nixpkgs-fmt;
        process-compose.redis-service = { config, ... }: {
          imports = [
            inputs.services-flake.processComposeModules.default
          ];
          services.redis-cluster."cluster1".enable = true;
          services.redis."redis".enable = true;
        };
        haskellProjects.default = {
          basePackages = config.haskellProjects.ghc98.outputs.finalPackages;
          autoWire = [ "packages" ];
        };
        packages.default = self'.packages.hedis;
        devShells.default = pkgs.mkShell {
          name = "hedis";
          inputsFrom = [
            config.haskellProjects.default.outputs.devShell
          ];
        };
      };
    };
}


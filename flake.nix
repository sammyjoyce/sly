{
  description = "sly: Nix flake for dev shells and packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };

        zig = pkgs.zigpkgs.master;

        zigFetchDeps = import (pkgs.path + "/pkgs/development/compilers/zig/fetcher.nix") {
          inherit (pkgs) lib runCommand;
          inherit zig;
        };

        zigDeps = zigFetchDeps {
          pname = "sly";
          version = "0.0.0";
          src = ./.;
          hash = pkgs.lib.fakeHash;
        };

        sly = pkgs.stdenv.mkDerivation {
          pname = "sly";
          version = "0.0.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.pkg-config zig ];
          buildInputs = [ pkgs.curl ];

          zigBuildFlags = [ "-Dcpu=baseline" "-Doptimize=ReleaseSafe" ];

          preBuild = ''
            export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
            ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          buildPhase = ''
            runHook preBuild
            zig build -j"${NIX_BUILD_CORES:-1}" ${pkgs.lib.escapeShellArgs zigBuildFlags} --verbose
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            zig build install ${pkgs.lib.escapeShellArgs zigBuildFlags} --verbose --prefix "$out"
            runHook postInstall
          '';

          doCheck = false;

          meta = with pkgs.lib; {
            description = "Shell AI command generator";
            homepage = "https://codeberg.org/sam/sly";
            license = licenses.mit;
            maintainers = with maintainers; [ ];
            mainProgram = "sly";
            platforms = platforms.unix;
          };
        };

        nixosModule = { config, lib, pkgs, ... }:
          let
            cfg = config.programs.sly;
          in
          {
            options.programs.sly = {
              enable = lib.mkEnableOption "Install and configure sly";
              package = lib.mkPackageOption pkgs "sly" { default = sly; };
              provider = lib.mkOption {
                type = lib.types.enum [ "anthropic" "gemini" "openai" "ollama" "echo" ];
                default = "anthropic";
                description = "Default AI provider (SLY_PROVIDER).";
              };
              anthropicApiKey = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Anthropic API key (ANTHROPIC_API_KEY). Avoid committing secrets to Nix store.";
              };
              geminiApiKey = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Google Gemini API key (GEMINI_API_KEY).";
              };
              openaiApiKey = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "OpenAI API key (OPENAI_API_KEY).";
              };
              openaiUrl = lib.mkOption {
                type = lib.types.str;
                default = "https://api.openai.com/v1/responses";
                description = "OpenAI API URL (SLY_OPENAI_URL).";
              };
              models = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = {
                  anthropic = "claude-3-5-sonnet-20241022";
                  gemini = "gemini-2.0-flash-exp";
                  openai = "gpt-4o";
                  ollama = "llama3.2";
                };
                description = "Model overrides for providers.";
              };
              promptExtend = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Additional system prompt text (SLY_PROMPT_EXTEND).";
              };
            };

            config = lib.mkIf cfg.enable {
              environment.systemPackages = [ cfg.package ];
              environment.variables = {
                SLY_PROVIDER = cfg.provider;
                SLY_ANTHROPIC_MODEL = cfg.models.anthropic;
                SLY_GEMINI_MODEL = cfg.models.gemini;
                SLY_OPENAI_MODEL = cfg.models.openai;
                SLY_OPENAI_URL = cfg.openaiUrl;
                SLY_OLLAMA_MODEL = cfg.models.ollama;
              }
              // (lib.optionalAttrs (cfg.promptExtend != null) { SLY_PROMPT_EXTEND = cfg.promptExtend; })
              // (lib.optionalAttrs (cfg.anthropicApiKey != null) { ANTHROPIC_API_KEY = cfg.anthropicApiKey; })
              // (lib.optionalAttrs (cfg.geminiApiKey != null) { GEMINI_API_KEY = cfg.geminiApiKey; })
              // (lib.optionalAttrs (cfg.openaiApiKey != null) { OPENAI_API_KEY = cfg.openaiApiKey; });
            };
          };
      in
      {
        packages = {
          default = sly;
          sly = sly;
        };

        apps.default = {
          type = "app";
          program = "${sly}/bin/sly";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.pkg-config
            pkgs.curl
            pkgs.git
            pkgs.zls
          ];
          ZIG_GLOBAL_CACHE_DIR = "${toString ./.}/.zig-cache";
        };

        overlays.default = final: prev: {
          sly = sly;
        };

        nixosModules.default = nixosModule;
      }
    );
}

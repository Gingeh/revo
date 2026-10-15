{
  description = "revo, the programming language";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs.lib) genAttrs;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forSystem =
        f: system:
        f system (
          import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          }
        );
      forEachSystem = f: genAttrs systems (forSystem f);
    in
    {
      overlays.default = final: _prev: {
        revo = final.callPackage (
          { stdenv, ... }:
          let
            zig = final.zig_0_17;
          in
            stdenv.mkDerivation {
              name = "revo";
              version = "git";
              src = ../../.;
              nativeBuildInputs = [ zig ];
              zigBuildFlags = [
                "-Dfeatures=lsp"    
              ];
              preBuild =
                let
                  zigDeps = zig.fetchDeps {
                    src = ../../.;
                    pname = "revo-deps";
                    version = "git";
                    fetchAll = true;
                    hash = "sha256-eXzXkv2ncitipYoRorPXj1zmJckAKS+pyCDMaCmU6bw=";
                    # NOTE: this hash has to be updated whenever dependencies are updated
                  };
                in
                "ln -s ${zigDeps} $ZIG_GLOBAL_CACHE_DIR/p";
            }
          ) { };

        revo-small = final.revo.overrideAttrs {
          zigBuildFlags = [
            "-Dfeatures="
            "-Doptimize=small"
          ];
        };

        buildRevoModule = final.callPackage (
          {
            stdenv,
            makeWrapper,
            revo-small,
          }:
          {
            name,
            version,
            src,
            entry-point ? "main",
            revo ? revo-small,
          }:
          stdenv.mkDerivation {
            inherit name version src;
            nativeBuildInputs = [ makeWrapper ];
            installPhase = ''
              mkdir -p $out/revo
              cp -r * $out/revo
              mkdir $out/bin
              makeWrapper "${revo}/bin/revo" "$out/bin/${name}" --add-flags "$out/revo/${entry-point}.rv"
            '';
          }
        ) { };
      };
      checks = forEachSystem (
        _: pkgs: {
          test = pkgs.revo.overrideAttrs (old: {
            name = "revo-check";
            doCheck = true;
          });
        }
      );
      packages = forEachSystem (
        _: pkgs: {
          inherit (pkgs) revo revo-small;
          default = pkgs.revo;
          modules = pkgs.buildRevoModule {
            name = "modules";
            version = "git";
            src = ./examples/modules;
          };
        }
      );
      devShells = forEachSystem (
        _: pkgs: {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              zig_0_17
              zls # 0.17 not currently on nixpkgs
            ];
          };
        }
      );
    };
}

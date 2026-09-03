{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        with pkgs;
        {
          default = stdenv.mkDerivation {
            name = "revo";
            version = "git";
            src = ./.;
            nativeBuildInputs = [ zig ];
            preBuild =
              let
                zigDeps = zig.fetchDeps {
                  src = ./.;
                  pname = "revo-deps";
                  version = "git";
                  fetchAll = true;
                  hash = "sha256-gw4SJ2EImQt3e7X1g4smnCcCDDa5j7BFnfM3tgB5YHg=";
                  # NOTE: this hash has to be updated whenever dependencies are updated
                };
              in
              "ln -s ${zigDeps} $ZIG_GLOBAL_CACHE_DIR/p";
          };

          build =
            {
              name,
              version,
              src,
              entry-point ? "main",
              revo ? default,
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
            };
          build-test = build {
            name = "modules";
            version = "git";
            src = ./examples/modules;
          };
        }
      );
      devShells = forEachSystem (system: {
        default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
          packages = with nixpkgs.legacyPackages.${system}; [
            zig
            zig-zlint
            zls
          ];
        };
      });
    };
}

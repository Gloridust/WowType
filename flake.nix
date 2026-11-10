{
  description = "WowType: WeChat-style pinyin input method for fcitx5";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # NixOS：i18n.inputMethod.fcitx5.addons = [ inputs.wowtype.packages.${system}.default ];
      packages = forAllSystems (pkgs: rec {
        wowtype = pkgs.callPackage ./nix/package.nix { };
        default = wowtype;
      });

      # 想用 pkgs.wowtype：nixpkgs.overlays = [ inputs.wowtype.overlays.default ];
      overlays.default = final: _prev: {
        wowtype = final.callPackage ./nix/package.nix { };
      };

      # nix flake check：装好的自检工具能用真实词库打出「你好」，设置界面的自测能过
      checks = forAllSystems (
        pkgs:
        let
          wowtype = self.packages.${pkgs.stdenv.hostPlatform.system}.wowtype;
        in
        {
          inherit wowtype;
          smoke = pkgs.runCommand "wowtype-smoke" { nativeBuildInputs = [ wowtype ]; } ''
            export HOME=$TMPDIR
            test -f ${wowtype}/lib/fcitx5/libwowtype.so
            test -f ${wowtype}/share/fcitx5/addon/wowtype.conf
            test -f ${wowtype}/share/fcitx5/inputmethod/wowtype.conf
            test -s ${wowtype}/share/wowtype/words.lm
            wowtype-check
            wowtype-show --lexicon ${wowtype}/share/wowtype/lexicon.tsv nihao > show.txt
            cat show.txt
            grep -q '1\.你好' show.txt
            wowtype-config --self-test
            touch $out
          '';
        }
      );
    };
}

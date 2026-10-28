{
  description = "touragent.nvim dev environment";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            neovim
            lua-language-server
            stylua
            selene
            just
            tmux
            git
          ];
          shellHook = ''
            # mini.test for the test suite (dev-only; the plugin itself has no deps)
            export TOURAGENT_MINI_PATH="${pkgs.vimPlugins.mini-nvim}"
            echo "[touragent.nvim] Environment ready."
          '';
        };
      }
    );
}

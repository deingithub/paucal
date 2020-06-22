with import (builtins.fetchTarball {
  # nixos-unstable on 2020-06-21
  url = "https://github.com/NixOS/nixpkgs/tarball/9480bae337095fd24f61380bce3174fdfe926a00";
  sha256 = "1n5bnnral5w60kf68d9jvs7px1w3hx53d8pyg9yxkf1s2n3791j2";
}) {};


crystal.buildCrystalPackage rec {
  pname = "Paucal";
  version = "unstable";

  buildInputs = [ openssl.dev sqlite-interactive.dev ];
  src = ./.;

  shardsFile = ./shards.nix;

}
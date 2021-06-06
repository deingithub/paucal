with import (builtins.fetchTarball {
  # nixos-unstable on 2020-06-21
  url = "https://github.com/NixOS/nixpkgs/tarball/befefe6f3f202c9945e9e8370422e0837339e7ae";
  sha256 = "17xpwz0fvz8kwniig7mkqi2grrppny4d4pl5dg28p49ahzmhp7r4";
}) {};


crystal.buildCrystalPackage rec {
  pname = "Paucal";
  version = "unstable";

  buildInputs = [ openssl.dev sqlite-interactive.dev ];
  src = ./.;

  shardsFile = ./shards.nix;
  format = "crystal";
  doCheck = false;
  doInstallCheck = false;

  crystalBinaries.Paucal.src = "src/Paucal.cr";
}

{ pkgs, config, ... }:

let
  bitcoind = pkgs.bitcoind;
  datadir = "${config.devenv.root}/.devenv/state/bitcoind";
  bitcoinConf = ./config/bitcoin.conf;
in
{
  packages = [
    bitcoind
    pkgs.openssl
    pkgs.pkg-config
    pkgs.curl
    pkgs.jq
  ];

  languages.rust.enable = true;

  processes.bitcoind.exec = ''
    mkdir -p ${datadir}
    exec ${bitcoind}/bin/bitcoind -datadir=${datadir} -conf=${bitcoinConf}
  '';

  enterShell = ''
    alias bitcoin-cli='bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf} -regtest'
    echo "Bitcoin Core (regtest, blocks-only) running at: 127.0.0.1:18443"
  '';
}


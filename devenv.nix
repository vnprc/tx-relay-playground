{ pkgs, config, ... }:

let
  bitcoind = pkgs.bitcoind;
  bitcoinCli = pkgs.bitcoin;
  initScript = "${config.devenv.root}/scripts/init-wallet.sh";
  datadir = "${config.devenv.root}/.devenv/state/bitcoind";
  bitcoinConf = ./config/bitcoin.conf;
in
{
  packages = [
    bitcoind
    bitcoinCli
    pkgs.openssl
    pkgs.pkg-config
    pkgs.curl
    pkgs.jq
  ];

  env = {
    BITCOIND_PATH = "${pkgs.bitcoind}/bin/bitcoin-cli";
  };

  languages.rust.enable = true;

  processes.bitcoind.exec = ''
    mkdir -p ${datadir}
    echo "Starting bitcoind..."
    ${bitcoind}/bin/bitcoind -datadir=${datadir} -conf=${bitcoinConf} -regtest &
    pid=$!

    echo "Waiting for bitcoind RPC..."
    timeout=60
    counter=0
    until ${bitcoinCli}/bin/bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf} -regtest -rpcuser=user -rpcpassword=password getblockchaininfo >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "ERROR: Timeout waiting for bitcoind RPC after ''${timeout}s"
        kill $pid 2>/dev/null || true
        exit 1
      fi
      if [ $((counter % 10)) -eq 0 ]; then
        echo "Still waiting for RPC... (''${counter}s)"
      fi
    done

    echo "Running init script..."
    ${initScript} || true

    wait $pid
  '';

  enterShell = ''
    alias bitcoin-cli='bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf} -regtest'
    echo "Bitcoin Core (regtest, blocks-only) running at: 127.0.0.1:18443"
  '';
}


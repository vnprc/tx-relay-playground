{ pkgs, config, ... }:

let
  bitcoind = pkgs.bitcoind;
  bitcoinCli = pkgs.bitcoin;
  initScript = "${config.devenv.root}/scripts/init-wallets.sh";
  datadir = "${config.devenv.root}/.devenv/state/bitcoind";
  bitcoinConf1 = ./config/bitcoin1.conf;
  bitcoinConf2 = ./config/bitcoin2.conf;
in
{
  packages = [
    bitcoind
    bitcoinCli
    pkgs.openssl
    pkgs.pkg-config
    pkgs.curl
    pkgs.jq
    pkgs.go
    pkgs.netcat
    pkgs.python3
    pkgs.git
    pkgs.gcc
    pkgs.gnumake
    pkgs.zlib
    pkgs.lmdb
    pkgs.flatbuffers
    pkgs.secp256k1
    pkgs.zstd
  ];

  env = {
    BITCOIND_PATH = "${pkgs.bitcoind}/bin/bitcoin-cli";
  };

  languages.rust.enable = true;

  processes.bitcoind1.exec = ''
    mkdir -p ${config.devenv.root}/logs
    mkdir -p ${datadir}
    exec > >(tee -a ${config.devenv.root}/logs/bitcoind1.log)
    exec 2>&1
    
    echo "[$(date)] bitcoind: Starting bitcoind..."
    ${bitcoind}/bin/bitcoind -datadir=${datadir} -conf=${bitcoinConf1} -regtest -port=18333 -rpcport=18443 &
    pid=$!

    echo "[$(date)] bitcoind: Waiting for bitcoind RPC..."
    timeout=60
    counter=0
    until ${bitcoinCli}/bin/bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf1} -regtest -rpcuser=user -rpcpassword=password getblockchaininfo >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] bitcoind: ERROR: Timeout waiting for bitcoind RPC after ''${timeout}s"
        kill $pid 2>/dev/null || true
        exit 1
      fi
      if [ $((counter % 10)) -eq 0 ]; then
        echo "[$(date)] bitcoind: Still waiting for RPC... (''${counter}s)"
      fi
    done

    echo "[$(date)] bitcoind: ✓ bitcoind RPC ready"

    # Connect to bitcoind2 once both are running
    echo "[$(date)] bitcoind: Connecting to peer bitcoind2..."
    sleep 2
    ${bitcoinCli}/bin/bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf1} -regtest -rpcuser=user -rpcpassword=password addnode "127.0.0.1:18445" "add" || true

    wait $pid
  '';

  processes.bitcoind2.exec = ''
    mkdir -p ${config.devenv.root}/logs
    mkdir -p ${config.devenv.root}/.devenv/state/bitcoind2
    exec > >(tee -a ${config.devenv.root}/logs/bitcoind2.log)
    exec 2>&1
    
    echo "[$(date)] bitcoind2: Starting second bitcoind on port 18444..."
    ${bitcoind}/bin/bitcoind -datadir=${config.devenv.root}/.devenv/state/bitcoind2 -conf=${bitcoinConf2} -regtest -port=18445 -rpcport=18444 &
    pid=$!

    echo "[$(date)] bitcoind2: Waiting for bitcoind RPC..."
    timeout=60
    counter=0
    until ${bitcoinCli}/bin/bitcoin-cli -datadir=${config.devenv.root}/.devenv/state/bitcoind2 -conf=${bitcoinConf2} -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 getblockchaininfo >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] bitcoind2: ERROR: Timeout waiting for bitcoind RPC after ''${timeout}s"
        kill $pid 2>/dev/null || true
        exit 1
      fi
      if [ $((counter % 10)) -eq 0 ]; then
        echo "[$(date)] bitcoind2: Still waiting for RPC... (''${counter}s)"
      fi
    done

    echo "[$(date)] bitcoind2: ✓ bitcoind2 RPC ready"

    # Connect to bitcoind1 to form network
    echo "[$(date)] bitcoind2: Connecting to peer bitcoind1..."
    sleep 2
    ${bitcoinCli}/bin/bitcoin-cli -datadir=${config.devenv.root}/.devenv/state/bitcoind2 -conf=${bitcoinConf2} -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 addnode "127.0.0.1:18333" "add" || true

    wait $pid
  '';

  processes.stirfry.exec = ''
    mkdir -p ${config.devenv.root}/logs
    mkdir -p ${config.devenv.root}/.devenv/state/stirfry
    cd ${config.devenv.root}/.devenv/state/stirfry
    exec > >(tee -a ${config.devenv.root}/logs/stirfry.log)
    exec 2>&1
    
    if [ ! -f strfry ]; then
      echo "[$(date)] strfry: Installing strfry..."
      if [ ! -d strfry-src ]; then
        echo "[$(date)] strfry: Cloning strfry repository..."
        git clone --recursive https://github.com/hoytech/strfry strfry-src
      fi
      
      cd strfry-src
      if [ ! -f strfry ]; then
        echo "[$(date)] strfry: Building strfry (this may take several minutes)..."
        # Fix the parallel-hashmap submodule issue
        cd golpe/external
        if [ -d parallel-hashmap ]; then
          echo "[$(date)] strfry: Fixing parallel-hashmap submodule..."
          rm -rf parallel-hashmap
        fi
        git clone https://github.com/greg7mdp/parallel-hashmap.git
        cd ../..
        
        echo "[$(date)] strfry: Running make setup-golpe..."
        make setup-golpe || true  # Continue even if setup-golpe fails
        echo "[$(date)] strfry: Running make -j4 (compiling, please wait)..."
        make -j4
        
        if [ -f strfry ]; then
          echo "[$(date)] strfry: ✓ strfry binary built successfully"
        else
          echo "[$(date)] strfry: ✗ strfry binary not found after build"
        fi
      fi
      cd ..
      
      if [ -f strfry-src/strfry ]; then
        cp strfry-src/strfry ./strfry
        echo "[$(date)] strfry: ✓ strfry binary copied to working directory"
      else
        echo "[$(date)] strfry: ERROR: strfry build failed, binary not found"
        exit 1
      fi
    fi
    
    if [ ! -f strfry.conf ]; then
      echo "[$(date)] strfry: Creating strfry config..."
      cp strfry-src/strfry.conf ./strfry.conf
    fi
    
    # Create database directory if it doesn't exist
    mkdir -p strfry-db
    
    echo "[$(date)] strfry: Starting strfry relay on port 7777..."
    ./strfry --config=strfry.conf relay
  '';

  processes.tx-relay-1.exec = ''
    mkdir -p ${config.devenv.root}/logs
    exec > >(tee -a ${config.devenv.root}/logs/tx-relay-1.log)
    exec 2>&1
    
    # Wait for bitcoind1 and strfry to be ready
    echo "[$(date)] tx-relay-1: Starting up..."
    echo "[$(date)] tx-relay-1: Waiting for bitcoind1 RPC..."
    timeout=120
    counter=0
    until bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf1} -regtest -rpcuser=user -rpcpassword=password getblockchaininfo >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] tx-relay-1: ERROR: Timeout waiting for bitcoind1 RPC after $timeout seconds"
        exit 1
      fi
      if [ $((counter % 30)) -eq 0 ]; then
        echo "[$(date)] tx-relay-1: Still waiting for bitcoind1 RPC... ($counter/$timeout seconds)"
      fi
    done
    echo "[$(date)] tx-relay-1: ✓ bitcoind1 RPC ready"
    
    echo "[$(date)] tx-relay-1: Waiting for strfry relay..."
    counter=0
    timeout=180
    until nc -z 127.0.0.1 7777 >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] tx-relay-1: ERROR: Timeout waiting for strfry relay after $timeout seconds"
        exit 1
      fi
      if [ $((counter % 30)) -eq 0 ]; then
        echo "[$(date)] tx-relay-1: Still waiting for strfry relay... ($counter/$timeout seconds)"
      fi
    done
    echo "[$(date)] tx-relay-1: ✓ strfry relay ready"
    
    # Auto-initialize wallets if needed
    echo "[$(date)] tx-relay-1: Checking if wallet initialization is needed..."
    HEIGHT=$(bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf1} -regtest -rpcuser=user -rpcpassword=password getblockcount 2>/dev/null || echo "0")
    if [ "$HEIGHT" -lt 102 ]; then
      echo "[$(date)] tx-relay-1: Block height is $HEIGHT, auto-initializing wallets..."
      ${initScript} || echo "[$(date)] tx-relay-1: Warning: Init script failed but continuing..."
    else
      echo "[$(date)] tx-relay-1: Block height is $HEIGHT, wallets should be ready"
    fi
    
    echo "[$(date)] tx-relay-1: Starting Bitcoin Transaction Relay Server 1..."
    cd ${config.devenv.root}
    cargo run --bin tx-relay-server 1 7779 18443
  '';

  processes.tx-relay-2.exec = ''
    mkdir -p ${config.devenv.root}/logs
    exec > >(tee -a ${config.devenv.root}/logs/tx-relay-2.log)
    exec 2>&1
    
    # Wait for bitcoind2 and strfry to be ready
    echo "[$(date)] tx-relay-2: Starting up..."
    echo "[$(date)] tx-relay-2: Waiting for bitcoind2 RPC..."
    timeout=120
    counter=0
    until bitcoin-cli -datadir=${config.devenv.root}/.devenv/state/bitcoind2 -conf=${bitcoinConf2} -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 getblockchaininfo >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] tx-relay-2: ERROR: Timeout waiting for bitcoind2 RPC after $timeout seconds"
        exit 1
      fi
      if [ $((counter % 30)) -eq 0 ]; then
        echo "[$(date)] tx-relay-2: Still waiting for bitcoind2 RPC... ($counter/$timeout seconds)"
      fi
    done
    echo "[$(date)] tx-relay-2: ✓ bitcoind2 RPC ready"
    
    echo "[$(date)] tx-relay-2: Waiting for strfry relay..."
    counter=0
    timeout=180
    until nc -z 127.0.0.1 7777 >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] tx-relay-2: ERROR: Timeout waiting for strfry relay after $timeout seconds"
        exit 1
      fi
      if [ $((counter % 30)) -eq 0 ]; then
        echo "[$(date)] tx-relay-2: Still waiting for strfry relay... ($counter/$timeout seconds)"
      fi
    done
    echo "[$(date)] tx-relay-2: ✓ strfry relay ready"
    
    # Auto-initialize wallets if needed (check from Node 2's perspective)
    echo "[$(date)] tx-relay-2: Checking if wallet initialization is needed..."
    HEIGHT=$(bitcoin-cli -datadir=${config.devenv.root}/.devenv/state/bitcoind2 -conf=${bitcoinConf2} -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 getblockcount 2>/dev/null || echo "0")
    if [ "$HEIGHT" -lt 102 ]; then
      echo "[$(date)] tx-relay-2: Block height is $HEIGHT, auto-initialization should be handled by tx-relay-1"
    else
      echo "[$(date)] tx-relay-2: Block height is $HEIGHT, wallets should be ready"
    fi
    
    echo "[$(date)] tx-relay-2: Starting Bitcoin Transaction Relay Server 2..."
    cd ${config.devenv.root}
    cargo run --bin tx-relay-server 2 7780 18444
  '';


  enterShell = ''
    alias bitcoin-cli='bitcoin-cli -datadir=${datadir} -conf=${bitcoinConf1} -regtest'
    echo "Bitcoin Core (regtest, blocks-only) running at: 127.0.0.1:18443"
    echo "Strfry nostr relay running at: ws://127.0.0.1:7777"
  '';
}


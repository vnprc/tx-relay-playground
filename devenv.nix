{ pkgs, config, ... }:

let
  bitcoind = pkgs.bitcoind;
  bitcoinCli = pkgs.bitcoin;
  initScript = "${config.devenv.root}/scripts/init-wallets.sh";
in
{
  packages = [
    bitcoind
    bitcoinCli
    pkgs.openssl
    pkgs.pkg-config
    pkgs.curl
    pkgs.jq
    pkgs.yq-go
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

  # Load environment variables from .env automatically
  dotenv.enable = true;

  env = {
    BITCOIND_PATH = "${pkgs.bitcoind}/bin/bitcoin-cli";
  };

  languages.rust.enable = true;

  processes.bitcoind1.exec = ''
    mkdir -p ${config.devenv.root}/logs
    exec > >(tee -a ${config.devenv.root}/logs/bitcoind1.log)
    exec 2>&1
    
    # Get chain-specific port configuration
    CHAIN="''${BITCOIN_CHAIN:-regtest}"
    NODE1_RPC=$(yq eval ".bitcoin.$CHAIN.node1.rpc" config/ports.toml)
    NODE1_P2P=$(yq eval ".bitcoin.$CHAIN.node1.p2p" config/ports.toml)
    NODE1_DATADIR=$(yq eval ".bitcoin.$CHAIN.node1.datadir" config/ports.toml)
    
    mkdir -p ${config.devenv.root}/.devenv/state/$NODE1_DATADIR
    
    # Determine chain flag and node1 specific settings
    CHAIN_FLAG=""
    NODE1_EXTRA_FLAGS=""
    case "$CHAIN" in
      "regtest") CHAIN_FLAG="-regtest" ;;
      "testnet4") 
        CHAIN_FLAG="-testnet4"
        NODE1_EXTRA_FLAGS="-blocksonly=1"
        ;;
      "signet") CHAIN_FLAG="-signet" ;;
    esac
    
    # Determine config file based on environment variable
    NODE1_CONFIG_TYPE="''${BITCOIN_NODE1_CONFIG:-base}"
    if [ "$NODE1_CONFIG_TYPE" = "permissive" ]; then
      NODE1_CONF="${config.devenv.root}/config/bitcoin-permissive.conf"
    else
      NODE1_CONF="${config.devenv.root}/config/bitcoin-base.conf"
    fi
    
    echo "[$(date)] bitcoind: Starting bitcoind1 (blocks-only for testnet4) with chain: $CHAIN on ports $NODE1_RPC/$NODE1_P2P using $NODE1_CONFIG_TYPE config..."
    ${bitcoind}/bin/bitcoind \
      -datadir=${config.devenv.root}/.devenv/state/$NODE1_DATADIR \
      -conf=$NODE1_CONF \
      $CHAIN_FLAG \
      $NODE1_EXTRA_FLAGS \
      -port=$NODE1_P2P \
      -rpcport=$NODE1_RPC &
    pid=$!

    echo "[$(date)] bitcoind: Waiting for bitcoind RPC..."
    timeout=60
    counter=0
    until ${bitcoinCli}/bin/bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE1_DATADIR \
      -conf=$NODE1_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE1_RPC \
      getblockchaininfo >/dev/null 2>&1; do
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
    NODE2_P2P=$(yq eval ".bitcoin.$CHAIN.node2.p2p" config/ports.toml)
    ${bitcoinCli}/bin/bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE1_DATADIR \
      -conf=$NODE1_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE1_RPC \
      addnode "127.0.0.1:$NODE2_P2P" "add" || true

    wait $pid
  '';

  processes.bitcoind2.exec = ''
    mkdir -p ${config.devenv.root}/logs
    exec > >(tee -a ${config.devenv.root}/logs/bitcoind2.log)
    exec 2>&1
    
    # Get chain-specific port configuration  
    CHAIN="''${BITCOIN_CHAIN:-regtest}"
    NODE2_RPC=$(yq eval ".bitcoin.$CHAIN.node2.rpc" config/ports.toml)
    NODE2_P2P=$(yq eval ".bitcoin.$CHAIN.node2.p2p" config/ports.toml)
    NODE2_DATADIR=$(yq eval ".bitcoin.$CHAIN.node2.datadir" config/ports.toml)
    
    mkdir -p ${config.devenv.root}/.devenv/state/$NODE2_DATADIR
    
    # Determine chain flag and node2 specific settings
    CHAIN_FLAG=""
    NODE2_EXTRA_FLAGS=""
    case "$CHAIN" in
      "regtest") CHAIN_FLAG="-regtest" ;;
      "testnet4") 
        CHAIN_FLAG="-testnet4"
        NODE2_EXTRA_FLAGS="-blocksonly=0"
        ;;
      "signet") CHAIN_FLAG="-signet" ;;
    esac
    
    # Determine config file based on environment variable
    NODE2_CONFIG_TYPE="''${BITCOIN_NODE2_CONFIG:-base}"
    if [ "$NODE2_CONFIG_TYPE" = "permissive" ]; then
      NODE2_CONF="${config.devenv.root}/config/bitcoin-permissive.conf"
    else
      NODE2_CONF="${config.devenv.root}/config/bitcoin-base.conf"
    fi
    
    echo "[$(date)] bitcoind2: Starting bitcoind2 (full tx relay for testnet4) with chain: $CHAIN on ports $NODE2_RPC/$NODE2_P2P using $NODE2_CONFIG_TYPE config..."
    ${bitcoind}/bin/bitcoind \
      -datadir=${config.devenv.root}/.devenv/state/$NODE2_DATADIR \
      -conf=$NODE2_CONF \
      $CHAIN_FLAG \
      $NODE2_EXTRA_FLAGS \
      -port=$NODE2_P2P \
      -rpcport=$NODE2_RPC &
    pid=$!

    echo "[$(date)] bitcoind2: Waiting for bitcoind RPC..."
    timeout=60
    counter=0
    until ${bitcoinCli}/bin/bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE2_DATADIR \
      -conf=$NODE2_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE2_RPC \
      getblockchaininfo >/dev/null 2>&1; do
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
    NODE1_P2P=$(yq eval ".bitcoin.$CHAIN.node1.p2p" config/ports.toml)
    ${bitcoinCli}/bin/bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE2_DATADIR \
      -conf=$NODE2_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE2_RPC \
      addnode "127.0.0.1:$NODE1_P2P" "add" || true

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
      # Enable verbose logging to see event relay activity
      sed -i 's/dumpInAll = false/dumpInAll = true/' strfry.conf
      sed -i 's/dumpInEvents = false/dumpInEvents = true/' strfry.conf
    fi
    
    # Create database directory if it doesn't exist
    mkdir -p strfry-db
    
    STRFRY1_PORT=$(yq eval '.nostr.strfry1' ${config.devenv.root}/config/ports.toml)
    echo "[$(date)] strfry: Starting strfry relay on port $STRFRY1_PORT..."
    ./strfry --config=strfry.conf relay
  '';

  processes.strfry2.exec = ''
    mkdir -p ${config.devenv.root}/logs
    mkdir -p ${config.devenv.root}/.devenv/state/strfry2
    cd ${config.devenv.root}/.devenv/state/strfry2
    exec > >(tee -a ${config.devenv.root}/logs/strfry2.log)
    exec 2>&1
    
    if [ ! -f strfry ]; then
      echo "[$(date)] strfry2: Waiting for strfry1 to build binary..."
      # Wait for strfry1 to build and be ready
      timeout=600  # 10 minutes timeout
      counter=0
      until [ -f ${config.devenv.root}/.devenv/state/stirfry/strfry ]; do
        sleep 2
        counter=$((counter + 2))
        if [ $counter -ge $timeout ]; then
          echo "[$(date)] strfry2: ERROR: Timeout waiting for strfry1 binary after $timeout seconds"
          exit 1
        fi
        if [ $((counter % 30)) -eq 0 ]; then
          echo "[$(date)] strfry2: Still waiting for strfry1 binary... ($counter/$timeout seconds)"
        fi
      done
      
      echo "[$(date)] strfry2: Copying strfry binary from strfry1..."
      cp ${config.devenv.root}/.devenv/state/stirfry/strfry ./strfry
      chmod +x ./strfry
      echo "[$(date)] strfry2: ✓ strfry binary copied successfully"
      
      # Also copy the config file template
      if [ -f ${config.devenv.root}/.devenv/state/stirfry/strfry-src/strfry.conf ]; then
        cp ${config.devenv.root}/.devenv/state/stirfry/strfry-src/strfry.conf ./strfry.conf.template
      fi
    fi
    
    # Load port configuration
    STRFRY1_PORT=$(yq eval '.nostr.strfry1' ${config.devenv.root}/config/ports.toml)
    STRFRY2_PORT=$(yq eval '.nostr.strfry2' ${config.devenv.root}/config/ports.toml)
    
    if [ ! -f strfry.conf ]; then
      echo "[$(date)] strfry2: Creating strfry config for port $STRFRY2_PORT..."
      if [ -f ./strfry.conf.template ]; then
        cp ./strfry.conf.template ./strfry.conf
      else
        # Fallback: copy from strfry1
        cp ${config.devenv.root}/.devenv/state/stirfry/strfry-src/strfry.conf ./strfry.conf
      fi
      # Update port to strfry2
      sed -i "s/port = $STRFRY1_PORT/port = $STRFRY2_PORT/" strfry.conf
      # Enable verbose logging to see event relay activity
      sed -i 's/dumpInAll = false/dumpInAll = true/' strfry.conf
      sed -i 's/dumpInEvents = false/dumpInEvents = true/' strfry.conf
    fi
    
    # Create database directory if it doesn't exist
    mkdir -p strfry-db
    
    echo "[$(date)] strfry2: Starting strfry relay on port $STRFRY2_PORT..."
    ./strfry --config=strfry.conf relay &
    STRFRY_PID=$!
    
    # Wait for strfry2 to start
    sleep 5
    
    # Start federation stream to strfry1
    echo "[$(date)] strfry2: Starting federation stream to strfry1..."
    ./strfry stream ws://127.0.0.1:$STRFRY1_PORT --dir both &
    STREAM_PID=$!
    
    # Wait for both processes
    wait $STRFRY_PID $STREAM_PID
  '';

  processes.tx-relay-1.exec = ''
    mkdir -p ${config.devenv.root}/logs
    exec > >(tee -a ${config.devenv.root}/logs/tx-relay-1.log)
    exec 2>&1
    
    # Get chain-specific configuration
    CHAIN="''${BITCOIN_CHAIN:-regtest}"
    NODE1_RPC=$(yq eval ".bitcoin.$CHAIN.node1.rpc" ${config.devenv.root}/config/ports.toml)
    NODE1_DATADIR=$(yq eval ".bitcoin.$CHAIN.node1.datadir" ${config.devenv.root}/config/ports.toml)
    STRFRY1_PORT=$(yq eval '.nostr.strfry1' ${config.devenv.root}/config/ports.toml)
    TXRELAY1_PORT=$(yq eval '.txrelay.server1' ${config.devenv.root}/config/ports.toml)
    
    # Wait for bitcoind1 and strfry to be ready
    echo "[$(date)] tx-relay-1: Starting up..."
    echo "[$(date)] tx-relay-1: Waiting for bitcoind1 RPC..."
    timeout=120
    counter=0
    # Determine chain flag from environment
    CHAIN_FLAG=""
    case "$CHAIN" in
      "regtest") CHAIN_FLAG="-regtest" ;;
      "testnet4") CHAIN_FLAG="-testnet4" ;;
      "signet") CHAIN_FLAG="-signet" ;;
    esac
    
    # Determine config file based on environment variable (same as bitcoind1)
    NODE1_CONFIG_TYPE="''${BITCOIN_NODE1_CONFIG:-base}"
    if [ "$NODE1_CONFIG_TYPE" = "permissive" ]; then
      NODE1_CONF="${config.devenv.root}/config/bitcoin-permissive.conf"
    else
      NODE1_CONF="${config.devenv.root}/config/bitcoin-base.conf"
    fi
    
    until bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE1_DATADIR \
      -conf=$NODE1_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE1_RPC \
      getblockchaininfo >/dev/null 2>&1; do
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
    until nc -z 127.0.0.1 $STRFRY1_PORT >/dev/null 2>&1; do
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
    HEIGHT=$(bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE1_DATADIR \
      -conf=$NODE1_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE1_RPC \
      getblockcount 2>/dev/null || echo "0")
    if [ "$HEIGHT" -lt 102 ]; then
      echo "[$(date)] tx-relay-1: Block height is $HEIGHT, auto-initializing wallets..."
      ${initScript} || echo "[$(date)] tx-relay-1: Warning: Init script failed but continuing..."
    else
      echo "[$(date)] tx-relay-1: Block height is $HEIGHT, wallets should be ready"
    fi
    
    echo "[$(date)] tx-relay-1: Starting Bitcoin Transaction Relay Server 1..."
    cd ${config.devenv.root}
    cargo run --bin tx-relay-server 1 $TXRELAY1_PORT $NODE1_RPC $STRFRY1_PORT
  '';

  processes.tx-relay-2.exec = ''
    mkdir -p ${config.devenv.root}/logs
    exec > >(tee -a ${config.devenv.root}/logs/tx-relay-2.log)
    exec 2>&1
    
    # Get chain-specific configuration
    CHAIN="''${BITCOIN_CHAIN:-regtest}"
    NODE2_RPC=$(yq eval ".bitcoin.$CHAIN.node2.rpc" ${config.devenv.root}/config/ports.toml)
    NODE2_DATADIR=$(yq eval ".bitcoin.$CHAIN.node2.datadir" ${config.devenv.root}/config/ports.toml)
    STRFRY2_PORT=$(yq eval '.nostr.strfry2' ${config.devenv.root}/config/ports.toml)
    TXRELAY2_PORT=$(yq eval '.txrelay.server2' ${config.devenv.root}/config/ports.toml)
    
    # Wait for bitcoind2 and strfry to be ready
    echo "[$(date)] tx-relay-2: Starting up..."
    echo "[$(date)] tx-relay-2: Waiting for bitcoind2 RPC..."
    timeout=120
    counter=0
    # Determine chain flag from environment
    CHAIN_FLAG=""
    case "$CHAIN" in
      "regtest") CHAIN_FLAG="-regtest" ;;
      "testnet4") CHAIN_FLAG="-testnet4" ;;
      "signet") CHAIN_FLAG="-signet" ;;
    esac
    
    # Determine config file based on environment variable (same as bitcoind2)
    NODE2_CONFIG_TYPE="''${BITCOIN_NODE2_CONFIG:-base}"
    if [ "$NODE2_CONFIG_TYPE" = "permissive" ]; then
      NODE2_CONF="${config.devenv.root}/config/bitcoin-permissive.conf"
    else
      NODE2_CONF="${config.devenv.root}/config/bitcoin-base.conf"
    fi
    
    until bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE2_DATADIR \
      -conf=$NODE2_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE2_RPC \
      getblockchaininfo >/dev/null 2>&1; do
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
    
    echo "[$(date)] tx-relay-2: Waiting for strfry2 relay..."
    counter=0
    timeout=300
    until nc -z 127.0.0.1 $STRFRY2_PORT >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ $counter -ge $timeout ]; then
        echo "[$(date)] tx-relay-2: ERROR: Timeout waiting for strfry2 relay after $timeout seconds"
        exit 1
      fi
      if [ $((counter % 30)) -eq 0 ]; then
        echo "[$(date)] tx-relay-2: Still waiting for strfry2 relay... ($counter/$timeout seconds)"
      fi
    done
    echo "[$(date)] tx-relay-2: ✓ strfry2 relay ready"
    
    # Auto-initialize wallets if needed (check from Node 2's perspective)
    echo "[$(date)] tx-relay-2: Checking if wallet initialization is needed..."
    HEIGHT=$(bitcoin-cli \
      -datadir=${config.devenv.root}/.devenv/state/$NODE2_DATADIR \
      -conf=$NODE2_CONF \
      $CHAIN_FLAG \
      -rpcuser=user \
      -rpcpassword=password \
      -rpcport=$NODE2_RPC \
      getblockcount 2>/dev/null || echo "0")
    if [ "$HEIGHT" -lt 102 ]; then
      echo "[$(date)] tx-relay-2: Block height is $HEIGHT, auto-initialization should be handled by tx-relay-1"
    else
      echo "[$(date)] tx-relay-2: Block height is $HEIGHT, wallets should be ready"
    fi
    
    echo "[$(date)] tx-relay-2: Starting Bitcoin Transaction Relay Server 2..."
    cd ${config.devenv.root}
    cargo run --bin tx-relay-server 2 $TXRELAY2_PORT $NODE2_RPC $STRFRY2_PORT
  '';



  enterShell = ''
    echo "🚀 TxRelay Development Environment"
    echo ""
    just --list 2>/dev/null || echo "Run 'just' to see available commands (installing...)"
  '';
}


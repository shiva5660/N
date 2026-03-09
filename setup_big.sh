#!/usr/bin/env bash
set -e

rm -rf nex
rm -rf nodes.txt
rm -rf nexus-network-amd
rm -rf nexus-network-intel
rm -rf nexus-network-global
rm -rf node_runner.sh

# ---- Clone the repo ----
git clone --depth 1 https://github.com/shiva5660/nex.git

# ---- Move required files ----
mv nex/nodes.txt .
mv nex/nexus-network-amd .
mv nex/nexus-network-intel .
mv nex/nexus-network-global .

# ---- Make binaries executable ----
chmod +x nexus-network-amd nexus-network-intel nexus-network-global

# ---- Cleanup ----
rm -rf nex

# ---- Ask for node number ----
read -p "Enter node number (line number from large_nodes.txt): " n
NODE_ID=$(sed -n "${n}p" large_nodes.txt)
if [ -z "$NODE_ID" ]; then
  echo "Invalid selection. Exiting."
  exit 1
fi

echo "Selected NODE_ID=$NODE_ID (line $n)"

rm -rf .idx

mkdir -p .idx

# ---- Write dev.nix ----
cat > .idx/dev.nix << 'DEVNIX'
{ pkgs, ... }:
{
  packages = [
    pkgs.curl
    pkgs.coreutils
    pkgs.util-linux
    pkgs.strace
  ];

  idx = {
    workspace = {
      onStart = {
        run = ''
          bash "$PWD/node_runner.sh"
        '';
      };
    };
  };
}
DEVNIX

# ---- Write node_runner.sh ----
cat > node_runner.sh << RUNNEREOF
#!/usr/bin/env bash
# No set -e here — we handle all errors manually

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"

# ======================================================
# CONFIG
# ======================================================
NODE_NUM="$n"
NODE_ID="$NODE_ID"

BOT1_TOKEN="8749364164:AAFaVifCSDVsHeEcnmMZXesHM9qyeOtEtV8"
BOT2_TOKEN="8304064824:AAGHxAdCPzCplBhKHlC1rp_-M6Ws6RVj2V4"
CHAT_ID="5765264116"

RETRY_WAIT=900
CRASH_THRESHOLD=30

WORKING_BINARY_FILE="\$SCRIPT_DIR/.last_working_binary"

# ======================================================
# HELPER: send Telegram message, chunked at 4096 chars
# ======================================================
tg_send() {
  local token="\$1"
  local text="\$2"
  local len=\${#text}
  local offset=0
  while [ \$offset -lt \$len ]; do
    local chunk="\${text:\$offset:4096}"
    curl -s -X POST "https://api.telegram.org/bot\${token}/sendMessage" \\
      -d chat_id="\$CHAT_ID" \\
      --data-urlencode "text=\$chunk" \\
      > /dev/null
    offset=\$(( offset + 4096 ))
    [ \$offset -lt \$len ] && sleep 1
  done
}

# ======================================================
# CPU detection
# ======================================================
CPU_VENDOR=\$(lscpu | grep "Vendor ID" | awk '{print \$3}')
echo "Detected CPU: \$CPU_VENDOR"

if [[ "\$CPU_VENDOR" == "AuthenticAMD" ]]; then
  CPU_BINARY="\$SCRIPT_DIR/nexus-network-amd"
elif [[ "\$CPU_VENDOR" == "GenuineIntel" ]]; then
  CPU_BINARY="\$SCRIPT_DIR/nexus-network-intel"
else
  CPU_BINARY="\$SCRIPT_DIR/nexus-network-global"
  echo "Unknown CPU: \$CPU_VENDOR — defaulting to global"
fi

# ======================================================
# Determine starting binary
# ======================================================
if [ -f "\$WORKING_BINARY_FILE" ]; then
  SAVED=\$(cat "\$WORKING_BINARY_FILE")
  if [ -f "\$SAVED" ]; then
    PRIMARY_BINARY="\$SAVED"
    echo "Resuming with last known working binary: \$PRIMARY_BINARY"
  else
    PRIMARY_BINARY="\$CPU_BINARY"
    echo "Saved binary missing, using CPU binary: \$PRIMARY_BINARY"
  fi
else
  PRIMARY_BINARY="\$CPU_BINARY"
  echo "First run — using CPU-matched binary: \$PRIMARY_BINARY"
fi

# ======================================================
# Startup notification via Bot 1
# ======================================================
tg_send "\$BOT1_TOKEN" "Node \$NODE_NUM started
NODE_ID: \$NODE_ID
CPU: \$CPU_VENDOR
Starting with: \$PRIMARY_BINARY"

# ======================================================
# run_binary: runs one binary, returns:
#   0 = ran then exited cleanly (code 0)
#   1 = crashed immediately (under CRASH_THRESHOLD seconds)
#   2 = ran for a while then exited with error
# NOTE: uses a temp file to pass result out because
#       subshells/pipes can swallow return codes
# ======================================================
run_binary() {
  local binary="\$1"
  local tmplog=\$(mktemp)
  local start_time=\$(date +%s)

  echo ">>> Starting \$binary ..."

  strace -f -e trace=process -o /dev/null \\
    \$binary start \\
      --headless \\
      --max-difficulty extra_large_3 \\
      --max-threads 24 \\
      --node-id \$NODE_ID \\
    2>&1 | tee "\$tmplog"
  local exit_code=\${PIPESTATUS[0]}

  local end_time=\$(date +%s)
  local runtime=\$(( end_time - start_time ))
  local output=\$(cat "\$tmplog")
  rm -f "\$tmplog"

  echo ">>> \$binary exited after \${runtime}s with code \$exit_code"

  if [ \$exit_code -eq 0 ]; then
    tg_send "\$BOT2_TOKEN" "Node \$NODE_NUM | \$binary exited cleanly after \${runtime}s.
NODE_ID: \$NODE_ID
Retrying same binary after 15min."
    return 0

  elif [ \$runtime -lt \$CRASH_THRESHOLD ]; then
    tg_send "\$BOT2_TOKEN" "CRASH: Node \$NODE_NUM | \$binary crashed in \${runtime}s (code \$exit_code).
NODE_ID: \$NODE_ID | CPU: \$CPU_VENDOR
Trying fallback binary.

--- Error ---
\$output"
    return 1

  else
    tg_send "\$BOT2_TOKEN" "EXIT: Node \$NODE_NUM | \$binary ran \${runtime}s then exited (code \$exit_code).
NODE_ID: \$NODE_ID | CPU: \$CPU_VENDOR
Retrying same binary after 15min.

--- Error ---
\$output"
    return 2
  fi
}

# ======================================================
# Main loop — forever
# ======================================================
CYCLE=0

while true; do
  CYCLE=\$(( CYCLE + 1 ))
  echo ""
  echo "=============================="
  echo " CYCLE \$CYCLE - Node \$NODE_NUM"
  echo " Primary: \$PRIMARY_BINARY"
  echo "=============================="

  # --- Try primary binary ---
  # Use 'run_binary ... || true' pattern so the loop never dies
  run_binary "\$PRIMARY_BINARY"
  PRIMARY_RESULT=\$?

  if [ \$PRIMARY_RESULT -eq 0 ] || [ \$PRIMARY_RESULT -eq 2 ]; then
    # Binary works — save it, wait 15min, retry same
    echo "\$PRIMARY_BINARY" > "\$WORKING_BINARY_FILE"
    echo "Working binary saved. Waiting 15min before Cycle \$(( CYCLE + 1 ))..."
    sleep \$RETRY_WAIT
    continue
  fi

  # PRIMARY_RESULT=1: crashed immediately — try global
  echo "Primary crashed immediately. Trying global fallback..."
  tg_send "\$BOT2_TOKEN" "Node \$NODE_NUM | Cycle \$CYCLE
\$PRIMARY_BINARY crashed. Trying global fallback..."

  run_binary "\$SCRIPT_DIR/nexus-network-global"
  GLOBAL_RESULT=\$?

  if [ \$GLOBAL_RESULT -eq 0 ] || [ \$GLOBAL_RESULT -eq 2 ]; then
    # Global works — promote to primary, save it
    PRIMARY_BINARY="\$SCRIPT_DIR/nexus-network-global"
    echo "\$PRIMARY_BINARY" > "\$WORKING_BINARY_FILE"
    echo "Global works. Promoted to primary. Waiting 15min..."
    tg_send "\$BOT2_TOKEN" "Node \$NODE_NUM | Cycle \$CYCLE
global binary works. Promoted to primary.
Waiting 15min -> Cycle \$(( CYCLE + 1 ))..."
    sleep \$RETRY_WAIT
    continue
  fi

  # Both crashed immediately
  echo "Both binaries crashed. Waiting 15min before Cycle \$(( CYCLE + 1 ))..."
  tg_send "\$BOT2_TOKEN" "BOTH FAILED: Node \$NODE_NUM | Cycle \$CYCLE
\$PRIMARY_BINARY and global both crashed immediately.
NODE_ID: \$NODE_ID
Waiting 15min -> Cycle \$(( CYCLE + 1 ))..."
  sleep \$RETRY_WAIT

done
RUNNEREOF

chmod +x node_runner.sh

echo ""
echo "=== .idx/dev.nix ==="
cat .idx/dev.nix
echo ""
echo "=== bash syntax check ==="
bash -n node_runner.sh && echo "SYNTAX OK"
echo ""
echo "Setup complete! NODE_NUM=$n  NODE_ID=$NODE_ID"

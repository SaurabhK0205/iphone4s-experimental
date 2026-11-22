#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=========================================================="
echo " Starting PhysicalAgent: iPhone 4S Desk Companion"
echo "=========================================================="

# 1. Check device connection
if ! ideviceinfo -s >/dev/null 2>&1; then
    echo "[!] Error: iPhone 4S not detected on USB. Please plug it in."
    exit 1
fi
echo "[+] iPhone 4S detected on USB."

# 2. Check/Start SSH iproxy (port 2222 -> 22)
if ! pgrep -fl "iproxy 2222 22" >/dev/null; then
    echo "[+] Starting iproxy for SSH (port 2222 -> 22)..."
    nohup iproxy 2222 22 >/tmp/iproxy_ssh.log 2>&1 &
    sleep 1
else
    echo "[+] SSH iproxy already running on port 2222."
fi

# 3. Check/Start Companion API iproxy (port 5555 -> 5000)
if ! pgrep -fl "iproxy 5555 5000" >/dev/null; then
    echo "[+] Starting iproxy for Companion API (port 5555 -> 5000)..."
    nohup iproxy 5555 5000 >/tmp/iproxy_companion.log 2>&1 &
    sleep 1
else
    echo "[+] Companion API iproxy already running on port 5555."
fi

# 4. Ensure PhysicalAgent.app is running on the iPhone
echo "[+] Ensuring PhysicalAgent is running on iPhone screen..."
ssh -i ~/.ssh/id_rsa_iphone -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 \
    "killall -0 PhysicalAgent 2>/dev/null || uiopen physicalagent://" >/dev/null 2>&1 || true

sleep 1

# 5. Launch Interactive Companion CLI via local virtual environment
"$DIR/.venv/bin/python3" desk_companion.py

#!/bin/bash
# —— PiBase Firewall – Database Port Hardening ——————————
# Run once on the Pi to secure exposed database ports.
#
# What this does:
# 1. Opens TCP ports 5432-5582 in UFW
# 2. Rate-limits connections per IP (max 10 concurrent)
# 3. Logs new connection attempts for monitoring
#
# Usage:
#  sudo bash setup-db-firewall.sh
#
# To undo:
#  sudo ufw delete allow 5432:5582/tcp
#  sudo iptables -D INPUT -p tcp --dport 5432:5582 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
#  sudo iptables -D INPUT -p tcp --dport 5432:5582 -m state --state NEW -j LOG --log-prefix "PIBASE-DB-CONN: "

set -euo pipefail

echo "=== PiBase Database Firewall Setup ==="

# —— 1. UFW: Allow database port range ——
echo "[1/3] Opening TCP ports 5432-5582 in UFW..."
sudo ufw allow 5432:5582/tcp comment "PiBase database access"

# —— 2. Rate limit: Max 10 concurrent connections per IP ——
echo "[2/3] Adding connection rate limit (max 10 per IP)..."

# Check if rule already exists to avoid duplicates
if ! sudo iptables -C INPUT -p tcp --dport 5432:5582 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset 2>/dev/null; then
    sudo iptables -A INPUT -p tcp --dport 5432:5582 \
        -m connlimit --connlimit-above 10 --connlimit-mask 32 \
        -j REJECT --reject-with tcp-reset
    echo " Added: reject connections above 10 per IP"
else
    echo " Already exists, skipping"
fi

# — 3. Log new connections —
echo "[3/3] Adding connection logging..."

if ! sudo iptables -C INPUT -p tcp --dport 5432:5582 -m state --state NEW -j LOG --log-prefix "PIBASE-DB-CONN: " 2>/dev/null; then
    sudo iptables -A INPUT -p tcp --dport 5432:5582 \
        -m state --state NEW -j LOG --log-prefix "PIBASE-DB-CONN: "
    echo " Added: log new connections with prefix PIBASE-DB-CONN"
else
    echo " Already exists, skipping"
fi

# — Persist iptables rules across reboots —
echo ""
echo "Saving iptables rules..."
if command -v netfilter-persistent &> /dev/null; then
    sudo netfilter-persistent save
else
    echo " WARNING: netfilter-persistent not installed."
    echo " Install with: sudo apt install iptables-persistent"
    echo " Then run:     sudo netfilter-persistent save"
fi

echo ""
echo "=== Firewall setup complete ==="
echo ""
echo "Current UFW status:"
sudo ufw status | grep -E "5432|Status"
echo ""
echo "View connection logs with:"
echo " sudo journalctl -k | grep PIBASE-DB-CONN"
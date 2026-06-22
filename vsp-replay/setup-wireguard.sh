#!/bin/bash
# ---- PiBase VPS Relay - WireGuard Setup (VPS side) ------------
# Run this script on the Oracle Cloud VPS to set up WireGuard
# and port forwarding for PiBase database access.
#
# Prerequisites:
# - Ubuntu 22.04+ on VPS
# - Pi's WireGuard public key (generated on Pi first)
# - Oracle Security List rules added:
#   UDP 51820 (WireGuard)
#   TCP 5432-5582 (database ports)
#
# Usage:
#   sudo bash setup-wireguard.sh <PI_PUBLIC_KEY>
#
# Example:
#   sudo bash setup-wireguard.sh "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

set -euo pipefail

PI_PUBLIC_KEY="${1:-}"

if [ -z "$PI_PUBLIC_KEY" ]; then
  echo "ERROR: Pi's WireGuard public key required"
  echo "Usage: sudo bash setup-wireguard.sh <PI_PUBLIC_KEY>"
  exit 1
fi

echo "=== PiBase VPS Relay - WireGuard Setup ==="

# --- 1. Install WireGuard ---
echo "[1/5] Installing WireGuard..."
apt update && apt install -y wireguard

# --- 2. Generate VPS keys (if not already generated) ---
if [ ! -f /etc/wireguard/private.key ]; then
  echo "[2/5] Generating WireGuard keys..."
  wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
  chmod 600 /etc/wireguard/private.key
else
  echo "[2/5] Keys already exist, skipping..."
fi

VPS_PRIVATE_KEY=$(cat /etc/wireguard/private.key)
VPS_PUBLIC_KEY=$(cat /etc/wireguard/public.key)

# --- 3. Detect network interface ---
echo "[3/5] Detecting network interface..."
NET_IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
echo " Detected: $NET_IFACE"

# --- 4. Create WireGuard config ---
echo "[4/5] Creating WireGuard config..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.100.1/24
ListenPort = 51820
PrivateKey = $VPS_PRIVATE_KEY

# Forward database ports to Pi through tunnel
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A PREROUTING -i $NET_IFACE -p tcp --dport 5432:5582 -j DNAT --to-destination 10.0.100.2
PostUp = iptables -A FORWARD -p tcp --dport 5432:5582 -d 10.0.100.2 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

PostDown = iptables -t nat -D PREROUTING -i $NET_IFACE -p tcp --dport 5432:5582 -j DNAT --to-destination 10.0.100.2
PostDown = iptables -D FORWARD -p tcp --dport 5432:5582 -d 10.0.100.2 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
PublicKey = $PI_PUBLIC_KEY
AllowedIPs = 10.0.100.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf

# --- 5. Enable and start WireGuard ---
echo "[5/5] Starting WireGuard..."
systemctl enable --now wg-quick@wg0

echo ""
echo "=== VPS WireGuard Setup Complete ==="
echo ""
echo "VPS Public Key (give this to Pi):"
echo " $VPS_PUBLIC_KEY"
echo ""
echo "VPS Tunnel IP: 10.0.100.1"
echo "Pi Tunnel IP: 10.0.100.2 (expected)"
echo ""
echo "Next: Run setup on Pi, then verify with:"
echo " ping 10.0.100.2"
echo " wg show"
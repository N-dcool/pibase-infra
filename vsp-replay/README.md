# VPS Relay - Oracle Cloud WireGuard Setup

## Why this exists

The Raspberry Pi is behind **CGNAT** (Carrier-Grade NAT). The ISP assigns a private IP (`10.x`) to the router's WAN interface, making port forwarding impossible. An Oracle Cloud free-tier VPS acts as a TCP relay – it has a static public IP (`92.4.79.91`) and forwards database traffic to the Pi through a WireGuard tunnel.

```
User (psql) -> VPS 92.4.79.91:5432 -> WireGuard tunnel -> Pi:5432 -> HAProxy -> DB container
                          iptables DNAT          10.0.100.1->2
```

## Network details

|          | VPS | Pi |
|----------|-----|----|
| **Public IP** | `92.4.79.91` | Behind CGNAT (no public IP) |
| **WireGuard IP** | `10.0.100.1` | `10.0.100.2` |
| **Provider** | Oracle Cloud Always Free ($0/month) | Raspberry Pi 5 at home |
| **OS** | Ubuntu 24.04 | Raspberry Pi OS (Debian) |
| **Role** | Listens UDP 51820, forwards TCP 5432-5582 | Runs all services, initiates tunnel |

## Quick setup (with script)

### Step 1: Generate Pi's WireGuard keys first (on Pi)
```bash
sudo apt update && sudo apt install -y wireguard
wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
sudo chmod 600 /etc/wireguard/private.key
cat /etc/wireguard/public.key
# Copy this key – you'll need it for the VPS script
```
### Step 2: Run setup script on VPS

```basg
# SSH into VPS
ssh -i <key> ubuntu@92.4.79.91

# Upload and run script
sudo bash setup-wireguard.sh "<PI_PUBLIC_KEY>"


# Example:
sudo bash setup-wireguard.sh "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

The script will:
1. Install WireGuard
2. Generate VPS keys (if not already present)
3. Detect the network interface (e.g. `ens3`)
4. Create `/etc/wireguard/wg0.conf` with iptables DNAT rules
5. Enable and start `wg-quick@wg0`
6. Print the **VPS public key** – copy this for the Pi

### Step 3: Run setup script on Pi

```bash
sudo bash infra/pi-core/wireguard/setup-wireguard.sh "<VPS_PUBLIC_KEY>" "92.4.79.91"
```

### Step 4: Open ports in Oracle Cloud Console

The script only configures WireGuard and iptables. You *must also* open ports in the Oracle Cloud Security List (web console):

1. Go to *Networking → Virtual Cloud Networks → your VCN → Subnet → Security List*
2. Add *Ingress Rules*:

| Source CIDR | Protocol	| Dest Port Range |	Description |
|---|---|---|---|
|`0.0.0.0/0`|	UDP	|`51820`	|WireGuard|
|`0.0.0.0/0`|	TCP	|`5432-5582`	|Database ports|

### Step 5: Open ports at OS level (Oracle iptables gotcha)

Oracle Ubuntu images have *built-in iptables rules* that block traffic even after you open the Security List. These are separate from WireGuard's PostUp rules and must be added manually:

```bash
# Allow WireGuard UDP
sudo iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT

# Allow database TCP ports
sudo iptables -I INPUT 1 -p tcp --dport 5432:5582 -j ACCEPT


# Allow forwarding to Pi (must be ABOVE Oracle's default REJECT rule)
sudo iptables -I FORWARD 1 -p tcp --dport 5432:5582 -d 10.0.100.2 -j ACCEPT
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Persist rules across reboots
sudo netfilter-persistent save
```

> **⚠️ Rule order matters!** Oracle's default FORWARD chain has a blanket `REJECT` rule. Always use `iptables -I FORWARD 1` (insert at position 1), never `-A` (append at end).

### Step 6: Verify

```bash
# On VPS – check tunnel status
sudo wg show
# Should show: latest handshake within last 25 seconds

# On VPS – ping Pi through tunnel
ping -c 3 10.0.100.2

# On Pi – ping VPS through tunnel
ping -c 3 10.0.100.1

# From any external machine – check TCP forwarding
nc -zv tcp.nareshchoudhary.com 5432
# Expected: Connection succeeded
```

---

### Manual setup (without script)

If you prefer to understand each step or the script doesn't fit your environment:

### On VPS

#### 1. Install WireGuard

```bash
sudo apt update && sudo apt install -y wireguard
```

#### 2. Generate keys
```bash
wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
sudo chmod 600 /etc/wireguard/private.key
```

#### 3. Find your network interface name

```bash
ip -o -4 route show to default | awk '{print $5}'
# Typical result: ens3 (Oracle), eth0 (others)
```

#### 4. Create WireGuard config

```bash
sudo nano /etc/wireguard/wg0.conf
```

```ini
[Interface]
Address = 10.0.100.1/24
ListenPort = 51820
PrivateKey = <VPS_PRIVATE_KEY>

# Forward database ports (5432-5582) to Pi through tunnel
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A PREROUTING -i ens3 -p tcp --dport 5432:5582 -j DNAT --to-destination 10.0.100.2
PostUp = iptables -A FORWARD -p tcp --dport 5432:5582 -d 10.0.100.2 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

PostDown = iptables -t nat -D PREROUTING -i ens3 -p tcp --dport 5432:5582 -j DNAT --to-destination 10.0.100.2
PostDown = iptables -D FORWARD -p tcp --dport 5432:5582 -d 10.0.100.2 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
PublicKey = <PI_PUBLIC_KEY>
AllowedIPs = 10.0.100.2/32
```

> Replace `ens3` with your actual interface from step 3.


```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

#### 5. Enable and start

```bash
sudo systemctl enable --now wg-quick@wg0
```

#### 6. Open Oracle Cloud Security List + OS-level iptables

See [Step 4](#step-4-open-ports-in-oracle-cloud-console) and [Step 5](#step-5-open-ports-at-os-level-oracle-iptables-gotcha) above.

### On Pi

#### 1. Install WireGuard
```bash
sudo apt update && sudo apt install -y wireguard
```

#### 2. Generate keys

```bash
wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
sudo chmod 600 /etc/wireguard/private.key
```

#### 3. Create WireGuard config

```bash
sudo nano /etc/wireguard/wg0.conf
```

```ini
[Interface]
Address = 10.0.100.2/24
PrivateKey = <PI_PRIVATE_KEY>

[Peer]

The Pi config is cut off at `[Peer]`. Based on the VPS config from the last screenshot, the `[Peer]` section should be:

PublicKey = <VPS_PUBLIC_KEY>
Endpoint = 92.4.79.91:51820
AllowedIPs = 10.0.100.1/32
PersistentKeepalive = 25
```

> `PersistentKeepalive = 25` is critical – the Pi is behind NAT, so it must send keepalive packets every 25 seconds to maintain the tunnel. Without this, the tunnel dies after ∼2 minutes of idle.

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

#### 4. Enable and start

```bash
sudo systemctl enable --now wg-quick@wg0
```

---

## How traffic flows

### Phase A – Direct port (fallback)

```
psql tcp.nareshchoudhary.com:5433
  → DNS: tcp.nareshchoudhary.com → 92.4.79.91
  → VPS iptables DNAT: :5433 → 10.0.100.2:5433
  → WireGuard tunnel → Pi:5433
  → PostgreSQL container (direct, no TLS)
```

### Phase B – SNI routing (primary)

```
psql "host=db-xxxx.db.nareshchoudhary.com:5432/mydb?sslmode=require&sslnegotiation=direct"
  → DNS: *.db.nareshchoudhary.com → 92.4.79.91
  → VPS iptables DNAT: :5432 → 10.0.100.2:5432
  → WireGuard tunnel → Pi:5432
  → HAProxy: TLS terminate (direct SSL + ALPN postgresql)
  → SNI extract: "db-xxxx" from ssl_fc_sni
  → Map lookup: db-xxxx → 5433
  → set-dst-port → 127.0.0.1:5433
  → PostgreSQL container ✅
```

> Phase B requires PostgreSQL 17+ client (`sslnegotiation=direct`). Older clients use Phase A.

---

## What the setup script does (line by line)

`setup-wireguard.sh` takes one argument: the Pi's WireGuard public key.

| Step | What | Command |
|---|---|---|
| 1 | Install WireGuard | `apt install -y wireguard` |
| 2 | Generate VPS keypair (idempotent) | `wg genkey \| tee private.key \| wg pubkey > public.key` |
| 3 | Detect network interface | `ip -o -4 route show to default \| awk '{print $5}'` |
| 4 | Write `/etc/wireguard/wg0.conf` | Interface + DNAT rules + Peer (Pi) |
| 5 | Enable systemd service | `systemctl enable --now wg-quick@wg0` |

**What the script does NOT do:**
- Open Oracle Cloud Security List ports (must be done in web console)
- Add OS-level iptables INPUT/FORWARD rules for Oracle's firewall (must be done manually, see Step 5)
- Persist OS-level iptables rules (`netfilter-persistent save`)
- Set up the Pi side (use `pi-core/wireguard/setup-wireguard.sh` for that)

---

## DNS records (Cloudflare)

These are required for the VPS relay to work:

| Type | Name | Value | Proxy | Purpose |
|---|---|---|---|---|
| A | `tcp` | `92.4.79.91` | **DNS only (grey ☁️)** | Phase A: `tcp.nareshchoudhary.com:5433-5582` |
| A | `*.db` | `92.4.79.91` | **DNS only (grey ☁️)** | Phase B: `db-xxxx.db.nareshchoudhary.com:5432` |

> **Must be grey cloud (DNS only).** Orange cloud (proxied) means Cloudflare intercepts TCP and drops non-HTTP traffic.


```bash
# Verify
nslookup tcp.nareshchoudhary.com  # Must return 92.4.79.91
nslookup test.db.nareshchoudhary.com # Must return 92.4.79.91 (wildcard)
```
---

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `nc -zv` to VPS times out | `sudo iptables -L INPUT -n` on VPS | Add INPUT rules (Step 5) |
| WireGuard shows `0 B received` on Pi | `sudo iptables -L INPUT -n \| grep 51820` on VPS | `sudo iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT` |
| Tunnel up but TCP forwarding fails | `sudo iptables -L FORWARD -n --line-numbers` on VPS | Oracle REJECT rule above ACCEPT? Re-insert with `-I FORWARD 1` |
| Rules gone after VPS reboot | `cat /etc/iptables/rules.v4` | `sudo netfilter-persistent save` |
| Tunnel drops after idle | `grep PersistentKeepalive /etc/wireguard/wg0.conf` on Pi | Must be `25` (not missing) |
| DNS returns Cloudflare IP (104.x) | Cloudflare dashboard → DNS | Change `tcp` / `*.db` to grey cloud (DNS only) |

## Maintenance

```bash
# Check tunnel status (either side)
sudo wg show

# Restart tunnel
sudo systemctl restart wg-quick@wg0

# View WireGuard logs
sudo journalctl -u wg-quick@wg0 -f

# Check iptables forwarding rules on VPS
sudo iptables -t nat -L PREROUTING -n | grep 5432
sudo iptables -L FORWARD -n --line-numbers | head -15

# Rotate keys (if compromised)
# 1. Generate new keys on both sides
# 2. Update wg0.conf on both sides
# 3. Restart wg-quick@wg0 on both sides
```
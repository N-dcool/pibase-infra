# Infrastructure Configs

## What's here
```

infra/
├── cloudflare-edge/
│   └── external-worker.js        → Worker script that sits between users and the Pi
│   
└── pi-core/
    ├── portainer/
    │   ├── traefik-stack.yml
    │   ├── watchtower-stack.yml
    │   └── pibase-api-stack.yml
    |
    └── cloudflared/
        └── config.yml   → Tunnel config (reference)

```
## How deploys work

```
git push → GitHub builds Docker image → DockerHub → Watchtower pulls it on Pi
```

No SSH needed. Takes ~5-10 min end to end.

## Portainer stacks (deploy in order)
| # | Stack        | File                                            | Env vars? |
|---|--------------|-------------------------------------------------|-----------|
| 1 | `traefik`    | `pi-core/portainer/traefik-stack.yml`           | No        |
| 2 | `watchtower` | `pi-core/portainer/watchtower-stack.yml`        | No        |
| 3 | `pibase-api` | `pi-core/portainer/pibase-api-stack.yml`        | Yes (3)   |

**pibase-api needs these env vars in Portainer UI:**
- `DOCKERHUB_USERNAME` – your DockerHub username
- `JWT_SECRET` – run `node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"`
- `ALLOWED_ORIGINS` – `https://db.nareshchoudhary.com`

## Docker 28+ API fix

Docker 28/29 dropped support for API versions below 1.44, which breaks Traefik,
Watchtower, and Portainer. Run this **once** on the Pi:

```bash
sudo systemctl edit docker.service
```
Add:

```ini
[Service]
Environment=DOCKER_MIN_API_VERSION=1.24
```

Then reload:

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

## Quick check
```bash
curl https://db.nareshchoudhary.com/api/health
```

If you get `{"status":"ok"}` – everything is working.

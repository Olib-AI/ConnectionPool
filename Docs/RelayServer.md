# Self-Hosting the Relay Server

[Back to README](../README.md)

Remote pools need a relay. The relay server is a standalone Rust project: [StealthRelay](https://github.com/Olib-AI/StealthRelay).

```bash
# Quick start with Docker
docker run -p 9090:9090 -p 127.0.0.1:9091:9091 ghcr.io/olib-ai/stealth-relay:latest

# With Docker Compose (recommended)
docker compose -f docker/docker-compose.yml up -d

# With Cloudflare Tunnel (production)
docker compose -f docker/docker-compose.yml \
               -f docker/docker-compose.cloudflared.yml up -d
```

See the [StealthRelay README](https://github.com/Olib-AI/StealthRelay) for full deployment documentation.

## Client-Side Notes

- First connection to a fresh server requires claiming it with the claim code printed in the Docker logs. See [Hosting a Remote Pool](QuickStart.md#hosting-a-remote-pool).
- Tunnel exit is off until the operator sets `[tunnel] enabled = true` and the pool host approves members. See [Security: Tunnel Exit](Security.md#tunnel-exit-vpn-like).
- Pool lifetime past host disconnect is governed by `[pool] host_offline_ttl_secs` and `empty_grace_secs`. See [Security: Pool Persistence](Security.md#pool-persistence-across-host-disconnect).

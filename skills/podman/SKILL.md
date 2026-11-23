---
name: podman
description: Run a docker-compose stack for tests inside the sandbox through the host's dedicated-user rootless podman API. Use when a ticket needs services (databases, queues, etc.) from a compose file, or mentions podman, podman-compose, docker compose, compose.test.yml, or integration tests that need containers.
---

# Running compose for tests

The sandbox has no Docker socket. When the repo is configured with the
container sidecar, `podman` and `podman-compose` are on `PATH` and
`CONTAINER_HOST` points at a dedicated-user rootless podman API on the host.

## Check it is available

```sh
command -v podman podman-compose
# The sidecar may still be starting on a freshly booted VM; retry briefly.
i=0
while [ "$i" -lt 30 ]; do
  podman --remote info >/dev/null 2>&1 && { echo "sidecar ready"; break; }
  i=$((i + 1))
  sleep 1
done
```

If `podman` is missing, or `podman --remote info` still fails after the retries,
the sidecar is not configured for this repo. Do not try to start a daemon or use
the host's `/var/run/docker.sock`; report that the test needs the container
sidecar.

## Write the compose file

Put it in the repo, e.g. `compose.test.yml`. Publish the ports the test needs
on `127.0.0.1`:

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: test
    ports:
      - "127.0.0.1:5432:5432"
```

Bind mounts must be under the repo (the runner only has access to the
workspace). Use relative paths:

```yaml
    volumes:
      - ./test/fixtures:/docker-entrypoint-initdb.d:ro
```

## Run it

```sh
podman-compose -f compose.test.yml up -d --wait
# run the test, e.g. cargo test
podman-compose -f compose.test.yml down -v
```

If the test runs in the sandbox, connect to `127.0.0.1:<published-port>`. If it
runs as a compose service, use `podman-compose run --rm tests` so it shares the
compose network and no extra ports are needed.

## Limits

- The runner is a separate user: it cannot read your home, so `~/.ssh` and
  other secrets are out of reach. Do not try to mount them.
- `--network=host` reaches the host VM's network; prefer the compose network.
- The API is unauthenticated on loopback. Do not expose it.
- Clean up with `down -v` so containers and volumes do not persist.

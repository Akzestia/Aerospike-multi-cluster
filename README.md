# Aerospike Multi‑Cluster Setup

Generate and run **multiple Aerospike Community Edition clusters** locally with one command. This tool ships a generator (`gen.sh`) that produces a clean `docker-compose.yml`, minimal per‑namespace configs, and helper scripts - including an auto‑wired **AQL** client.

---

## Features

- Spin up **one or many clusters** (one per namespace)
- **Configurable replicas** per namespace via `-r`
  - `-r 1` → a **single node** named exactly as the namespace (no `-0` suffix)
  - `-r N` → nodes `ns-0 .. ns-(N-1)`

- Minimal, **non‑deprecated** Aerospike configs
- A dedicated **tools** container with `aql` preinstalled
- `aql.sh` overview prints a concise `docker ps` table; `aql.sh <container>` opens interactive AQL
- `setup.sh` copies configs into containers and restarts them
- `update-configs.sh` regenerates `./config/*.conf` from `config.yaml`

---

## Requirements

- Docker Engine and **docker compose v2** (or `docker-compose`)
- Bash (GNU)
- Optional: `uuidgen` (nice to have) and `yq` (for richer YAML parsing)

---

## Quick Start

1. **Prepare namespaces input**

**Plain list (recommended for quick start)**

```txt
prod-users
prod-sessions
test-data
test-cache
```

**YAML map (namespace → config path)**

```yaml
prod-users: ./config/prod-users.conf
prod-sessions: ./config/prod-sessions.conf
test-data: ./config/test-data.conf
test-cache: ./config/test-cache.conf
```

2. **Generate**

```bash
# Single node per namespace; container name equals namespace
./gen.sh -f namespaces.txt

# Or: N replicas per namespace
./gen.sh -f namespaces.txt -r 3
```

3. **Start**

```bash
cd aerospike-clusters
docker compose up -d
```

4. **Overview & AQL**

```bash
# Show cluster containers (name | status | ports)
./aql.sh

# Open interactive AQL to a node
./aql.sh prod-users      # when -r 1
./aql.sh prod-users-0    # when -r > 1
```

5. **Apply configs into running nodes**

```bash
# Uses namespaces.yaml (ns → ./config/ns.conf)
./setup.sh
# Or specify a mapping file
./setup.sh -y ./namespaces.yaml
```

6. **Regenerate configs from config.yaml**

```bash
./update-configs.sh
```

---

## What Gets Generated

```
aerospike-clusters/
├─ aql.sh                  # overview & AQL helper
├─ config/                 # per‑namespace Aerospike configs (*.conf)
├─ config.yaml             # minimal schema → generate *.conf
├─ docker-compose.yml      # all clusters + tools container
├─ namespaces.yaml         # ns → config path mapping
├─ setup.sh                # copy configs & restart nodes
└─ update-configs.sh       # rebuild *.conf from config.yaml
```

**Minimal Aerospike config template** (per namespace):

```conf
service {
    cluster-name docker
}

logging {
    console { context any info }
}

network {
    service  { address any; port 3000 }
    heartbeat{ mode mesh; address local; port 3002; interval 150; timeout 10 }
    fabric   { address local; port 3001 }
}

namespace <ns> {
    replication-factor <r>
    storage-engine device {
        file /opt/aerospike/data/<ns>.dat
        filesize 4G
        read-page-cache true
    }
}
```

> The `replication-factor` inside the namespace equals the `-r` value you pass to `gen.sh`.

---

## Usage Details

### `gen.sh`

```bash
./gen.sh [-f FILE] [-r REPLICAS] [namespace1 namespace2 ...]
```

- `-f FILE`:
  - **Plain list**: one namespace per line
  - **YAML map**: `namespace: ./config/namespace.conf`

- `-r REPLICAS` (default **1**):
  - `1` → single node named **exactly** as the namespace; volume `namespace-data`
  - `N>1` → nodes `namespace-0..namespace-(N-1)`; volumes `namespace-data-0..`

- **Ports** start at `30000` and increase by `+2` per node

### `aql.sh`

- No args → prints `docker ps` table filtered to your cluster containers
- With a container → opens interactive `aql` via the tools container

### `setup.sh`

- Reads `namespaces.yaml` map and copies each config into all matching containers (`ns` or `ns-<N>`) and restarts them

### `update-configs.sh`

- Rewrites `./config/<ns>.conf` from `./config.yaml` (minimal fields only). If `yq` is present, it’s used; otherwise a simple parser is used.

---

## Troubleshooting

- **Tools container can’t start or needs sudo**

  ```bash
  sudo ./aql.sh
  ```

- **Deprecated/unknown Aerospike parameters**
  - Ensure you deploy the generated minimal configs:

    ```bash
    ./update-configs.sh && ./setup.sh
    ```

- **No containers in overview**
  - Did you start the stack?

    ```bash
    docker compose up -d
    ```

---

## Cleanup

```bash
cd aerospike-clusters
docker compose down       # stop
docker compose down -v    # stop + remove volumes (data loss)
```

---

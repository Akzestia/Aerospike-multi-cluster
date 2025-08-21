
#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Aerospike multi-cluster generator
# =========================================
# Usage:
#   ./gen.sh [-f FILE] [-r REPLICAS] [namespace1 namespace2 ...]
#   -f FILE     : namespaces list (plain lines) or YAML map "ns: ./config/ns.conf"
#   -r REPLICAS : number of nodes per namespace.
#                 default 1 -> single node named exactly as namespace (no -N).
#                 r>1      -> nodes ns-0..ns-(r-1)
# Output: ./aerospike-clusters
# =========================================

die() { echo "Error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

slugify() {
  local s="${1// /-}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$s" ]] || s="ns"
  printf '%s' "$s"
}

make_uuid() {
  if have uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
  else
    date +%s%N | md5sum | awk '{print $1}'
  fi
}

# -------------------------
# Parse args
# -------------------------
INPUT_FILE=""
REPLICAS=1

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -f) shift; [[ $# -gt 0 ]] || die "Missing filename after -f"; INPUT_FILE="$1"; shift ;;
    -r) shift; [[ $# -gt 0 ]] || die "Missing value after -r"; REPLICAS="$1"; shift ;;
    --) shift; break ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [-f FILE] [-r REPLICAS] [namespace ...]
  -f FILE     : namespaces file (plain list or yaml map "ns: ./config/ns.conf")
  -r REPLICAS : nodes per namespace (default: 1). r=1 -> container named exactly as namespace. r>1 -> ns-0..ns-(r-1).
USAGE
      exit 0
      ;;
    *) break ;;
  esac
done

# Validate REPLICAS
if ! [[ "$REPLICAS" =~ ^[0-9]+$ ]] || (( REPLICAS < 1 )); then
  die "-r must be a positive integer"
fi

declare -a NAMESPACES=()
declare -A MAP_CONF=()

read_plain_list() {
  local file="$1"
  [[ -f "$file" ]] || die "File '$file' not found"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line="$(echo "$line" | xargs)"
    [[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo "Skip invalid ns: $line" >&2; continue; }
    NAMESPACES+=("$line")
  done < "$file"
}

read_yaml_map() {
  local file="$1"
  [[ -f "$file" ]] || die "File '$file' not found"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9][A-Za-z0-9_-]*)[[:space:]]*:[[:space:]]*(.+\.conf)[[:space:]]*$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val; val="$(echo "${BASH_REMATCH[2]}" | xargs)"
      NAMESPACES+=("$key")
      MAP_CONF["$key"]="$val"
    fi
  done < "$file"
}

if [[ -n "$INPUT_FILE" ]]; then
  case "$INPUT_FILE" in
    *.yml|*.yaml) read_yaml_map "$INPUT_FILE" ;;
    *)            read_plain_list "$INPUT_FILE" ;;
  esac
fi

# Add CLI namespaces
if [[ $# -gt 0 ]]; then
  for ns in "$@"; do
    [[ "$ns" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo "Skip invalid ns: $ns" >&2; continue; }
    NAMESPACES+=("$ns")
  done
fi

# Dedup
declare -A seen=(); declare -a NS_FINAL=()
for ns in "${NAMESPACES[@]}"; do
  [[ -z "${seen[$ns]+x}" ]] && { NS_FINAL+=("$ns"); seen["$ns"]=1; }
done
NAMESPACES=("${NS_FINAL[@]}")
[[ ${#NAMESPACES[@]} -gt 0 ]] || die "No namespaces provided"

# -------------------------
# Prepare dirs
# -------------------------
OUT_DIR="./aerospike-clusters"
CFG_DIR="$OUT_DIR/config"
mkdir -p "$CFG_DIR"

TOOLS_UUID="$(make_uuid)"
TOOLS_CONTAINER_NAME="aerospike-tools-${TOOLS_UUID}"

# -------------------------
# docker-compose.yml
# -------------------------
COMPOSE="$OUT_DIR/docker-compose.yml"
echo "services:" > "$COMPOSE"
port_counter=30000
declare -a SLUGS=()

for ns in "${NAMESPACES[@]}"; do
  ns_slug="$(slugify "$ns")"
  SLUGS+=("$ns_slug")

  echo "  # ${ns} Cluster Configuration" >> "$COMPOSE"

  # Generate nodes
  if (( REPLICAS == 1 )); then
    # Single node, exact name
    svc="${ns_slug}"
    vol="${ns_slug}-data"
    port="$port_counter"

    cat <<YAML >> "$COMPOSE"
  ${svc}:
    image: aerospike/aerospike-server:latest
    container_name: ${svc}
    hostname: ${svc}
    volumes:
      - ${vol}:/opt/aerospike/data
    ports:
      - "${port}:3000"
    networks:
      - ${ns_slug}-network
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 15000
        hard: 15000
YAML

    port_counter=$((port_counter + 2))
  else
    # Multi-node, with suffixes
    for ((i=0; i<REPLICAS; i++)); do
      svc="${ns_slug}-${i}"
      vol="${ns_slug}-data-${i}"
      port=$((port_counter + i*2))
      cat <<YAML >> "$COMPOSE"
  ${svc}:
    image: aerospike/aerospike-server:latest
    container_name: ${svc}
    hostname: ${svc}
    volumes:
      - ${vol}:/opt/aerospike/data
    ports:
      - "${port}:3000"
    networks:
      - ${ns_slug}-network
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 15000
        hard: 15000
YAML
    done
    port_counter=$((port_counter + REPLICAS*2))
  fi

  echo >> "$COMPOSE"
done

# Tools service
{
  echo "  # Aerospike Tools"
  cat <<YAML
  aerospike-tools:
    image: aerospike/aerospike-tools:latest
    container_name: ${TOOLS_CONTAINER_NAME}
    entrypoint: ["/bin/sh", "-c"]
    command: ["while true; do sleep 3600; done"]
    networks:
YAML
  for ns in "${NAMESPACES[@]}"; do
    echo "      - $(slugify "$ns")-network"
  done
  cat <<'YAML'
    restart: unless-stopped

networks:
YAML
} >> "$COMPOSE"

# Networks
for ns in "${NAMESPACES[@]}"; do
  ns_slug="$(slugify "$ns")"
  {
    echo "  ${ns_slug}-network:"
    echo "    driver: bridge"
  } >> "$COMPOSE"
done

# Volumes
{
  echo
  echo "volumes:"
} >> "$COMPOSE"

for ns in "${NAMESPACES[@]}"; do
  ns_slug="$(slugify "$ns")"
  if (( REPLICAS == 1 )); then
    echo "  ${ns_slug}-data:" >> "$COMPOSE"
  else
    for ((i=0; i<REPLICAS; i++)); do
      echo "  ${ns_slug}-data-${i}:" >> "$COMPOSE"
    done
  fi
done

# -------------------------
# config.yaml (minimal)
# -------------------------
CONFIG_YAML="$OUT_DIR/config.yaml"
{
  echo "# Aerospike namespace configuration parameters"
  echo "namespaces:"
} > "$CONFIG_YAML"

for ns in "${NAMESPACES[@]}"; do
  ns_slug="$(slugify "$ns")"
  cat <<YAML >> "$CONFIG_YAML"
  ${ns}:
    replication-factor: ${REPLICAS}
    storage-engine:
      file: /opt/aerospike/data/${ns_slug}.dat
      filesize: 4G
      read-page-cache: true
YAML
done

# -------------------------
# namespaces.yaml (ns -> conf path)
# -------------------------
NAMESPACES_YAML="$OUT_DIR/namespaces.yaml"
{
  echo "# Aerospike namespace configuration mapping"
  echo "# Format: namespace: path/to/config/file"
} > "$NAMESPACES_YAML"

for ns in "${NAMESPACES[@]}"; do
  if [[ -n "${MAP_CONF[$ns]:-}" ]]; then
    echo "  ${ns}: ${MAP_CONF[$ns]}" >> "$NAMESPACES_YAML"
  else
    echo "  ${ns}: ./config/${ns}.conf" >> "$NAMESPACES_YAML"
  fi
done

# -------------------------
# Minimal conf per namespace
# -------------------------
for ns in "${NAMESPACES[@]}"; do
  ns_slug="$(slugify "$ns")"
  conf_path="$CFG_DIR/${ns}.conf"
  cat <<CONF > "$conf_path"
# Aerospike database configuration file
# Minimal dev template

# This stanza must come first.
service {
    cluster-name docker
}

logging {
    # Send log messages to stdout
    console {
        context any info
    }
}

network {
    service {
        address any
        port 3000

        # access-address <IPADDR>
    }

    heartbeat {
        mode mesh
        address local
        port 3002
        interval 150
        timeout 10
    }

    fabric {
        address local
        port 3001
    }
}

namespace ${ns} {
    replication-factor ${REPLICAS}

    storage-engine device {
        file /opt/aerospike/data/${ns_slug}.dat
        filesize 4G
        read-page-cache true
    }
}
CONF
done

# -------------------------
# aql.sh helper
#   - overview: only docker ps summary (raw)
#   - works with single-node (no suffix) and multi-node (-N)
# -------------------------
AQL="$OUT_DIR/aql.sh"
cluster_pattern="$(printf "%s|" "${SLUGS[@]}")"; cluster_pattern="${cluster_pattern%|}"

cat > "$AQL" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_CONTAINER_NAME="${TOOLS_CONTAINER_NAME}"
cluster_pattern="${cluster_pattern}"
EOF

cat >> "$AQL" <<'AQLSH'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_file="$script_dir/docker-compose.yml"

DOCKER=(docker)
COMPOSE=()

need_sudo() { ! docker ps >/dev/null 2>&1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

setup_docker_cmds() {
  if need_sudo; then
    if sudo -n docker ps >/dev/null 2>&1; then
      DOCKER=(sudo docker)
    else
      echo "Error: Docker requires sudo. Run with sudo."
      exit 1
    fi
  fi

  if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    COMPOSE=("${DOCKER[@]}" compose)
  elif have_cmd docker-compose && docker-compose version >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    echo "Error: docker compose / docker-compose not found."
    exit 1
  fi
}

container_exists() { "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qE "^$1$"; }
container_running() { "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qE "^$1$"; }

list_containers() {
  # Match "<slug>" OR "<slug>-<digits>"
  "${DOCKER[@]}" ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
    | grep -E "^(${cluster_pattern})(-[0-9]+)?\b" || true
}

overview() {
  setup_docker_cmds
  echo "=== Containers (name | status | ports) ==="
  list_containers
}

ensure_tools_up() {
  if container_exists "$TOOLS_CONTAINER_NAME"; then
    if ! container_running "$TOOLS_CONTAINER_NAME"; then
      "${DOCKER[@]}" start "$TOOLS_CONTAINER_NAME" >/dev/null
    fi
    echo "$TOOLS_CONTAINER_NAME"; return
  fi
  echo "Starting aerospike-tools service..."
  setup_docker_cmds
  "${COMPOSE[@]}" -f "$compose_file" up -d aerospike-tools
  for _ in {1..20}; do
    container_running "$TOOLS_CONTAINER_NAME" && { echo "$TOOLS_CONTAINER_NAME"; return; }
    # Fallback to any aerospike-tools-* the compose created
    alt="$("${DOCKER[@]}" ps --format '{{.Names}}' | grep -E '^aerospike-tools-[0-9a-f-]+$' | head -n1 || true)"
    [[ -n "$alt" ]] && { echo "$alt"; return; }
    sleep 1
  done
  echo "Error: aerospike-tools not running."; exit 1
}

usage() {
  cat <<USAGE
Usage:
  $0                 # Overview: docker ps table
  $0 --overview      # Same as above
  $0 --list          # Same as above
  $0 <container>     # Open interactive AQL to that node
USAGE
}

main() {
  if [[ $# -eq 0 || "${1:-}" == "--overview" || "${1:-}" == "--list" ]]; then
    overview; exit 0
  fi

  setup_docker_cmds

  target="$1"
  if ! container_exists "$target"; then
    echo "Error: Container '$target' not found."; echo; overview; exit 1
  fi
  if ! container_running "$target"; then
    "${DOCKER[@]}" start "$target" >/dev/null || true
    sleep 1
  fi

  tools="$(ensure_tools_up)"

  echo "Opening AQL against '$target' ..."
  exec "${DOCKER[@]}" exec -it "$tools" aql -h "$target"
}

main "$@"
AQLSH
chmod +x "$AQL"

# -------------------------
# setup.sh — copy conf into each container (single or multi)
# -------------------------
SETUP="$OUT_DIR/setup.sh"
cat > "$SETUP" <<'SETUPSH'
#!/usr/bin/env bash
set -euo pipefail

YAML_FILE="./namespaces.yaml"

while getopts "y:h" opt; do
  case "$opt" in
    y) YAML_FILE="$OPTARG" ;;
    h) echo "Usage: $0 [-y namespaces.yaml]"; exit 0 ;;
    *) echo "Usage: $0 [-y namespaces.yaml]"; exit 1 ;;
  esac
done

[[ -f "$YAML_FILE" ]] || { echo "Error: $YAML_FILE not found"; exit 1; }

slugify() {
  local s="${1// /-}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$s" ]] || s="ns"
  printf '%s' "$s"
}

# Parse map (with yq if available; else regex)
declare -A MAP=()
if command -v yq >/dev/null 2>&1; then
  while IFS= read -r ns; do
    path=$(yq -r ".\"$ns\"" "$YAML_FILE")
    [[ -n "$path" && "$path" != "null" ]] && MAP["$ns"]="$path"
  done < <(yq -r 'keys[]' "$YAML_FILE" | sed -E '/^#|^\s*$/d')
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9][A-Za-z0-9_-]*)[[:space:]]*:[[:space:]]*(.+\.conf)[[:space:]]*$ ]]; then
      ns="${BASH_REMATCH[1]}"; path="$(echo "${BASH_REMATCH[2]}" | xargs)"
      MAP["$ns"]="$path"
    fi
  done < "$YAML_FILE"
fi

apply_ns() {
  local ns="$1" conf="$2"
  local slug; slug="$(slugify "$ns")"
  [[ -f "$conf" ]] || { echo "Warn: missing conf '$conf' for '$ns' (skip)"; return; }

  # Find containers for this namespace: slug OR slug-<digits>
  mapfile -t nodes < <(docker ps -a --format '{{.Names}}' | grep -E "^(${slug}|${slug}-[0-9]+)$" || true)
  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "No containers for '$ns' found (slug=$slug)"; return
  fi

  for c in "${nodes[@]}"; do
    [[ -z "$c" ]] && continue
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "Starting $c ..."
      docker start "$c" >/dev/null || true
      sleep 1
    fi
    echo "Copy $conf -> $c:/etc/aerospike/aerospike.conf"
    docker cp "$conf" "$c:/etc/aerospike/aerospike.conf"
    echo "Restart $c"
    docker restart "$c" >/dev/null
  done
}

for ns in "${!MAP[@]}"; do
  apply_ns "$ns" "${MAP[$ns]}"
done

echo "Done."
SETUPSH
chmod +x "$SETUP"

# -------------------------
# update-configs.sh (minimal fields only)
# -------------------------
UPDCFG="$OUT_DIR/update-configs.sh"
cat > "$UPDCFG" <<'UPDSH'
#!/usr/bin/env bash
set -euo pipefail

CFG_YAML="./config.yaml"
OUT_DIR="./config"
mkdir -p "$OUT_DIR"

have() { command -v "$1" >/dev/null 2>&1; }

def_rf=1
def_filesize=4G
def_readpc=true

if [[ ! -f "$CFG_YAML" ]]; then
  echo "Error: $CFG_YAML not found"; exit 1
fi

if have yq; then
  for ns in $(yq -r '.namespaces | keys[]' "$CFG_YAML"); do
    rf=$(yq -r ".namespaces.\"$ns\".\"replication-factor\" // \"${def_rf}\"" "$CFG_YAML")
    sf=$(yq -r ".namespaces.\"$ns\".\"storage-engine\".file // \"/opt/aerospike/data/${ns}.dat\"" "$CFG_YAML")
    ss=$(yq -r ".namespaces.\"$ns\".\"storage-engine\".filesize // \"${def_filesize}\"" "$CFG_YAML")
    rpc=$(yq -r ".namespaces.\"$ns\".\"storage-engine\".\"read-page-cache\" // \"${def_readpc}\"" "$CFG_YAML")

    cat > "$OUT_DIR/${ns}.conf" <<CONF
# Aerospike database configuration file
# Minimal dev template

# This stanza must come first.
service {
    cluster-name docker
}

logging {
    console {
        context any info
    }
}

network {
    service {
        address any
        port 3000
    }
    heartbeat {
        mode mesh
        address local
        port 3002
        interval 150
        timeout 10
    }
    fabric {
        address local
        port 3001
    }
}

namespace ${ns} {
    replication-factor ${rf}
    storage-engine device {
        file ${sf}
        filesize ${ss}
        read-page-cache ${rpc}
    }
}
CONF
    echo "Generated $OUT_DIR/${ns}.conf"
  done
else
  # awk fallback (very simple)
  awk -v outdir="$OUT_DIR" -v def_rf="$def_rf" -v def_fs="$def_filesize" -v def_rpc="$def_readpc" '
    /^\s*namespaces:\s*$/ { in=1; next }
    in && /^\s{2}[A-Za-z0-9_-]+:\s*$/ {
      if (ns!="") flush();
      ns=$1; gsub(":","",ns)
      rf=def_rf; file="/opt/aerospike/data/" ns ".dat"; size=def_fs; rpc=def_rpc
      next
    }
    in && ns!="" {
      if ($0 ~ /^\s{4}replication-factor:\s*/) { rf=$2 }
      else if ($0 ~ /^\s{4}storage-engine:\s*$/) { se=1 }
      else if (se && $0 ~ /^\s{6}file:\s*/) { file=$2 }
      else if (se && $0 ~ /^\s{6}filesize:\s*/) { size=$2 }
      else if (se && $0 ~ /^\s{6}read-page-cache:\s*/) { rpc=$2 }
    }
    END { if (ns!="") flush() }
    function flush(){
      f=outdir "/" ns ".conf"
      print "# Aerospike database configuration file\n# Minimal dev template\n" > f
      print "service {\n    cluster-name docker\n}\n" >> f
      print "logging {\n    console {\n        context any info\n    }\n}\n" >> f
      print "network {\n    service { address any; port 3000 }\n    heartbeat { mode mesh; address local; port 3002; interval 150; timeout 10 }\n    fabric { address local; port 3001 }\n}\n" >> f
      print "namespace " ns " {\n    replication-factor " rf "\n    storage-engine device {\n        file " file "\n        filesize " size "\n        read-page-cache " rpc "\n    }\n}\n" >> f
      close(f)
      ns=""; se=0
    }
  ' "$CFG_YAML"
fi

echo "Done."
UPDSH
chmod +x "$UPDCFG"

# -------------------------
# Summary
# -------------------------
chmod +x "$AQL" "$SETUP" "$UPDCFG"

echo "Generated Docker Compose with ${#NAMESPACES[@]} namespaces, replicas per ns: ${REPLICAS}"
printf ' - %s\n' "${NAMESPACES[@]}"
echo "Output: $OUT_DIR"
echo "  - docker-compose.yml"
echo "  - config.yaml       (replication-factor=${REPLICAS})"
echo "  - namespaces.yaml"
echo "  - config/*.conf     (minimal template)"
echo "  - aql.sh            (overview = docker ps table)"
echo "  - setup.sh          (auto-detect nodes)"
echo "  - update-configs.sh"
echo "Tools container name: ${TOOLS_CONTAINER_NAME}"
echo
echo "Port assignments:"
pc=30000
for ns in "${NAMESPACES[@]}"; do
  ns_slug="$(slugify "$ns")"
  if (( REPLICAS == 1 )); then
    echo "  ${ns_slug}: ${pc}"
    pc=$((pc+2))
  else
    printf "  %s:" "${ns_slug}"
    for ((i=0;i<REPLICAS;i++)); do
      printf " %d" $((pc+i*2))
    done
    echo
    pc=$((pc+REPLICAS*2))
  fi
done
echo
echo "Start clusters:"
echo "  cd $OUT_DIR && docker compose up -d"
echo
echo "Setup config files:"
echo "  ./setup.sh"
echo
echo "Cluster Overview:"
echo "  ./aql.sh"
echo
echo "AQL to a node:"
if (( REPLICAS == 1 )); then
  echo "  ./aql.sh $(slugify "${NAMESPACES[0]}")"
else
  echo "  ./aql.sh $(slugify "${NAMESPACES[0]}")-0"
fi

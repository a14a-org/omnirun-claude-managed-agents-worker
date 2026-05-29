#!/bin/bash
set -euo pipefail

# Build Claude Managed Agents WORKER rootfs from Docker image for Firecracker.
# Run on the server as root.
#
# This template hosts Anthropic's self-hosted "Managed Agents" worker. Unlike
# the claude-code template, the agent loop + model + skills hosting run on
# Anthropic's side; this VM only runs the Go `ant` CLI worker, which polls a
# work queue, claims a session, downloads skills, runs tool calls
# (bash/read/write/edit/glob/grep) on the local filesystem, and posts results
# back. The worker needs only /bin/bash plus a few CLI tools — NO Node/npm and
# NO Claude Code npm package.
#
# Prerequisites:
# - Docker installed
# - Agent binary (OmniRun in-VM agent) at /opt/omnirun/bin/agent
# - LVM volume group vg0 with thinpool
#
# ===========================================================================
# PINNED `ant` CLI version + checksum. Bump these together when upgrading.
# The checksum is verified against the downloaded binary before it is baked
# into the rootfs; a mismatch aborts the build (supply-chain protection).
#
# Version + sha256 are PINNED to Anthropic's official release: the checksum
# below was taken from ant_1.10.0_checksums.txt (the line for
# ant_1.10.0_linux_amd64.tar.gz). The build re-downloads and verifies against
# it; a mismatch aborts the build (supply-chain protection). To upgrade, bump
# ANT_VERSION and replace ANT_SHA256 with the value from the new checksums file.
# ===========================================================================
ANT_VERSION="1.10.0"                                                          # pinned (official checksum)
ANT_SHA256="6d8145901edc81276d5ca803ea823ddcf18452b0449354283b91fe448984b215" # pinned (official checksum)
ANT_URL="https://github.com/anthropics/anthropic-cli/releases/download/v${ANT_VERSION}/ant_${ANT_VERSION}_linux_amd64.tar.gz"

echo "=== Building Claude Managed Agents Worker Rootfs (ant ${ANT_VERSION}) ==="

AGENT_BIN="/opt/omnirun/bin/agent"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_DIR="/tmp/rootfs-build-claude-agent"
ROOTFS_IMG="/opt/omnirun/rootfs-claude-agent.ext4"
ROOTFS_SIZE="16G"
VG="vg0"
THINPOOL="thinpool"
LV="golden-claude-agent-snap"

# Check prerequisites
if [ ! -f "$AGENT_BIN" ]; then
    echo "ERROR: Agent binary not found at $AGENT_BIN"
    exit 1
fi

# Clean up from previous runs
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# --- Build Docker image with all tools ---
echo "Building Docker image..."
DOCKERFILE=$(mktemp)
cat > "$DOCKERFILE" << DOCKEREOF
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Base system packages. The Go \`ant\` worker only needs bash + a handful of
# CLI tools that the worker shells out to (git for clones, ripgrep for grep,
# jq for JSON, curl/ca-certificates for downloading skills over HTTPS).
# Intentionally NO Node/npm and NO @anthropic-ai/claude-code.
RUN apt-get update && apt-get install -y --no-install-recommends \\
    ca-certificates \\
    curl \\
    git \\
    jq \\
    ripgrep \\
    sudo \\
    less \\
    vim-tiny \\
    procps \\
    iptables \\
    iproute2 \\
    && rm -rf /var/lib/apt/lists/*

# --- Bake the pinned Go \`ant\` CLI worker, with sha256 verification ---
RUN set -eux; \\
    cd /tmp; \\
    curl -fsSL "${ANT_URL}" -o ant.tar.gz; \\
    echo "${ANT_SHA256}  ant.tar.gz" | sha256sum -c -; \\
    tar -xzf ant.tar.gz; \\
    install -m 0755 ant /usr/local/bin/ant; \\
    rm -rf /tmp/ant.tar.gz /tmp/ant; \\
    /usr/local/bin/ant --version || true

# Worker filesystem layout expected by Managed Agents:
#   /workspace          - working dir for tool calls
#   /workspace/skills   - downloaded skills land in /workspace/skills/<name>/
#   /mnt/session/outputs - session outputs are written here
RUN mkdir -p /workspace /workspace/skills /mnt/session/outputs

# Build seed-entropy (CRNG fix for Firecracker VMs)
COPY seed-entropy.c /tmp/seed-entropy.c
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \\
    && gcc -static -O2 -o /usr/local/bin/seed-entropy /tmp/seed-entropy.c \\
    && rm /tmp/seed-entropy.c \\
    && apt-get purge -y gcc libc6-dev && apt-get autoremove -y \\
    && rm -rf /var/lib/apt/lists/*

# Non-root user to run the worker (avoid running tool calls as root).
RUN useradd -m -s /bin/bash coder \\
    && chown -R coder:coder /workspace /mnt/session

DOCKEREOF

BUILD_CTX=$(mktemp -d)
cp "$SCRIPT_DIR/seed-entropy.c" "$BUILD_CTX/"
docker build -t claude-agent-rootfs -f "$DOCKERFILE" "$BUILD_CTX"
rm -rf "$DOCKERFILE" "$BUILD_CTX"

# --- Export Docker image to directory ---
echo "Exporting filesystem..."
CONTAINER_ID=$(docker create claude-agent-rootfs)
docker export "$CONTAINER_ID" | tar -xf - -C "$ROOTFS_DIR"
docker rm "$CONTAINER_ID"

# --- Inject agent binary ---
echo "Injecting agent binary..."
cp "$AGENT_BIN" "$ROOTFS_DIR/usr/local/bin/agent"
chmod +x "$ROOTFS_DIR/usr/local/bin/agent"

# seed-entropy is already compiled inside the Docker image

# --- Create init script ---
cat > "$ROOTFS_DIR/init-firecracker.sh" << 'INITEOF'
#!/bin/bash

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Seed entropy for CRNG
/usr/local/bin/seed-entropy 2>/dev/null || true

# Configure network from kernel cmdline
CMDLINE=$(cat /proc/cmdline)
if echo "$CMDLINE" | grep -q "ip="; then
    IP_CONFIG=$(echo "$CMDLINE" | grep -oP 'ip=\K[^ ]+')
    GUEST_IP=$(echo "$IP_CONFIG" | cut -d: -f1)
    GATEWAY=$(echo "$IP_CONFIG" | cut -d: -f3)
    NETMASK=$(echo "$IP_CONFIG" | cut -d: -f4)

    ip addr add "${GUEST_IP}/${NETMASK}" dev eth0
    ip link set eth0 up
    ip route add default via "$GATEWAY"
else
    ip addr add 172.20.0.200/24 dev eth0
    ip link set eth0 up
    ip route add default via 172.20.0.1
fi

# Set up DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# Set hostname and hosts file
hostname sandbox
echo "127.0.0.1 localhost sandbox" > /etc/hosts
echo "::1 localhost" >> /etc/hosts

# Load environment variables from /etc/environment if it exists
if [ -f /etc/environment ]; then
    set -a
    . /etc/environment
    set +a
fi

# Start agent
echo "Starting agent..."
exec /usr/local/bin/agent
INITEOF

chmod +x "$ROOTFS_DIR/init-firecracker.sh"

# --- Create ext4 image ---
echo "Creating ext4 image ($ROOTFS_SIZE)..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1 count=0 seek="$ROOTFS_SIZE" 2>/dev/null
mkfs.ext4 -F -q "$ROOTFS_IMG"

# Mount and copy
MOUNT_DIR="/tmp/rootfs-mount-claude-agent"
mkdir -p "$MOUNT_DIR"
mount -o loop "$ROOTFS_IMG" "$MOUNT_DIR"
cp -a "$ROOTFS_DIR/." "$MOUNT_DIR/"
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo "Rootfs image created at $ROOTFS_IMG"

# --- Import into LVM ---
echo "Importing rootfs into LVM..."

# Remove old golden LV if exists
if lvs "$VG/$LV" &>/dev/null; then
    echo "Removing old golden LV..."
    lvremove -f "$VG/$LV"
fi

# Create thin LV and copy rootfs into it
SIZE_BYTES=$(stat -c %s "$ROOTFS_IMG")
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))

lvcreate --type thin --name "$LV" --virtualsize "${SIZE_MB}M" --thinpool "$THINPOOL" "$VG"

# Copy rootfs to LV
dd if="$ROOTFS_IMG" of="/dev/$VG/$LV" bs=4M status=progress

echo "Golden LV created: /dev/$VG/$LV"

# Clean up
rm -rf "$ROOTFS_DIR"

echo ""
echo "=== Claude Managed Agents Worker Rootfs Build Complete ==="
echo "Golden LV: /dev/$VG/$LV"
echo "Next: Run create-snapshot-claude-agent.sh to create the Firecracker golden snapshot"

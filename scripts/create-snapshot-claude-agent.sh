#!/bin/bash
set -euo pipefail

# Create Firecracker golden snapshot for the claude-agent template.
# Boot a VM with 4 vCPU + 8GB RAM, wait for agent, pause, snapshot.
# Run on the server as root.
#
# IMPORTANT: The TAP device name used here (tap0) gets baked into the snapshot.
# All snapshot restores must use a TAP device with the same name.

echo "=== Creating Claude Managed Agents Worker Golden Snapshot ==="

FC_BIN="/usr/local/bin/firecracker"
KERNEL="/opt/omnirun/vmlinux"
SNAPSHOT_DIR="/opt/omnirun/snapshots/claude-agent"
SOCKET="/tmp/fc-golden-claude-agent.sock"
BRIDGE="fc-br0"
GUEST_IP="172.20.0.200"
GATEWAY="172.20.0.1"
TAP="tap0"
NETNS="fc-golden-ca"
ROOTFS="/dev/vg0/golden-claude-agent-snap"

VCPU_COUNT=4
MEM_SIZE_MIB=8192

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    exit 1
fi

if [ ! -e "$ROOTFS" ]; then
    echo "ERROR: Golden rootfs not found at $ROOTFS"
    echo "Run build-rootfs-claude-agent.sh first"
    exit 1
fi

# Clean up from previous runs
rm -f "$SOCKET"
rm -f "$SNAPSHOT_DIR/mem_file" "$SNAPSHOT_DIR/snapshot_file"
mkdir -p "$SNAPSHOT_DIR"

cleanup() {
    echo "Cleaning up..."
    ip netns del "$NETNS" 2>/dev/null || true
    rm -f "$SOCKET"
    pkill -f "fc-golden-claude-agent.sock" 2>/dev/null || true
}
trap cleanup EXIT

# --- Set up network namespace with TAP ---
echo "Creating network namespace and TAP device..."
ip netns del "$NETNS" 2>/dev/null || true
ip netns add "$NETNS"

# Create veth pair: vg-ca (host side) <-> vg-ca-ns (namespace side)
ip link add vg-ca type veth peer name vg-ca-ns
ip link set vg-ca master "$BRIDGE"
ip link set vg-ca up
ip link set vg-ca-ns netns "$NETNS"

# Inside the namespace: create a bridge connecting the veth and tap0
ip netns exec "$NETNS" ip link add br0 type bridge
ip netns exec "$NETNS" ip link set vg-ca-ns master br0
ip netns exec "$NETNS" ip link set vg-ca-ns up
ip netns exec "$NETNS" ip link set br0 up

# Create TAP inside namespace (name=tap0 — this gets baked into snapshot)
ip netns exec "$NETNS" ip tuntap add dev "$TAP" mode tap
ip netns exec "$NETNS" ip link set "$TAP" master br0
ip netns exec "$NETNS" ip link set "$TAP" up

# --- Start Firecracker inside the namespace ---
echo "Starting Firecracker in namespace ($VCPU_COUNT vCPU, ${MEM_SIZE_MIB}MB RAM)..."
ip netns exec "$NETNS" $FC_BIN --api-sock "$SOCKET" &
FC_PID=$!
sleep 0.5

fc_api() {
    local method=$1
    local path=$2
    local body=$3
    curl -s --unix-socket "$SOCKET" \
        -X "$method" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "http://localhost${path}"
}

# --- Configure VM ---
echo "Configuring VM..."

fc_api PUT /boot-source '{
    "kernel_image_path": "'"$KERNEL"'",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off random.trust_cpu=on init=/init-firecracker.sh ip='"$GUEST_IP"'::'"$GATEWAY"':255.255.255.0::eth0:off"
}'

fc_api PUT /drives/rootfs '{
    "drive_id": "rootfs",
    "path_on_host": "'"$ROOTFS"'",
    "is_root_device": true,
    "is_read_only": false
}'

fc_api PUT /network-interfaces/eth0 '{
    "iface_id": "eth0",
    "host_dev_name": "'"$TAP"'",
    "guest_mac": "AA:FC:00:00:00:01"
}'

fc_api PUT /machine-config '{
    "vcpu_count": '"$VCPU_COUNT"',
    "mem_size_mib": '"$MEM_SIZE_MIB"'
}'

# --- Start VM ---
echo "Starting VM..."
fc_api PUT /actions '{"action_type": "InstanceStart"}'

# --- Wait for agent ---
echo "Waiting for agent at $GUEST_IP:8080..."
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
    if curl -s --connect-timeout 1 "http://$GUEST_IP:8080/health" | grep -q "ok"; then
        echo "Agent healthy after ${i}s"
        break
    fi
    if [ "$i" -eq "$MAX_WAIT" ]; then
        echo "ERROR: Agent not responding after ${MAX_WAIT}s"
        kill $FC_PID 2>/dev/null
        exit 1
    fi
    sleep 1
done

# --- Pause and snapshot ---
echo "Pausing VM..."
fc_api PATCH /vm '{"state": "Paused"}'
sleep 0.5

echo "Creating snapshot (this may take a while for ${MEM_SIZE_MIB}MB mem_file)..."
fc_api PUT /snapshot/create '{
    "snapshot_type": "Full",
    "snapshot_path": "'"$SNAPSHOT_DIR/snapshot_file"'",
    "mem_file_path": "'"$SNAPSHOT_DIR/mem_file"'"
}'

echo "Snapshot created!"
ls -lh "$SNAPSHOT_DIR/"

# --- Stop VM ---
echo "Stopping VM..."
kill $FC_PID 2>/dev/null
wait $FC_PID 2>/dev/null || true

echo ""
echo "=== Claude Managed Agents Worker Golden Snapshot Complete ==="
echo "Snapshot files:"
echo "  $SNAPSHOT_DIR/mem_file (~${MEM_SIZE_MIB}MB)"
echo "  $SNAPSHOT_DIR/snapshot_file"
echo ""
echo "TAP name baked into snapshot: $TAP"
echo "Each sandbox restore must use netns with a TAP named '$TAP'"
echo ""
echo "NOTE: Sandbox creation with 8GB mem_file will take ~4-5s (vs ~840ms for 512MB)"
echo "Max concurrent claude-agent sandboxes: ~7 (8GB × 7 = 56GB, server has 62GB)"

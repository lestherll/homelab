#!/usr/bin/env bash
# Find a machine that is sitting in maintenance mode, by MAC.
#
# Terraform has to talk to a node BEFORE that node has the address the
# inventory assigns it. Talos in maintenance mode "runs by default a DHCP
# client on all physical network interfaces", so the machine has an address —
# just not a predictable one. That is the whole gap: fleet/nodes.yaml says
# 192.168.0.222, the machine is on whatever the router handed out, and
# terraform_data.maintenance_ready used to poll the former and time out.
#
# The alternative was a DHCP reservation, which works and is NOT
# version-controlled — it lives in router NVRAM you cannot diff or restore.
# This keeps the MAC in fleet/nodes.yaml as the only identifier, which is the
# same one the machine config's interface selector already uses.
#
# ARP rather than a port scan, deliberately: ARP maps MAC to address directly,
# which is exactly the lookup we have. A :50000 sweep would find every Talos
# node and then need a second step to tell them apart.
#
# Terraform `external` protocol: JSON in on stdin, flat string JSON out.
#   in : {"mac":"aa:bb:...","expected_address":"192.168.0.222"}
#   out: {"address":"192.168.0.87"}

set -euo pipefail

INPUT="$(cat)"
MAC="$(printf '%s' "$INPUT" | sed -n 's/.*"mac"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
EXPECTED="$(printf '%s' "$INPUT" | sed -n 's/.*"expected_address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

[ -n "$MAC" ]      || { echo "no mac in input" >&2; exit 1; }
[ -n "$EXPECTED" ] || { echo "no expected_address in input" >&2; exit 1; }

# Normalise to lower-case, no leading zeros per octet. macOS `arp` prints
# `0:11:22:...` where the inventory writes `00:11:22:...`, so comparing the
# raw strings silently never matches — which would look like "machine not
# found" rather than like a formatting bug.
norm() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ':' '\n' | sed 's/^0*\(.\)/\1/' | paste -sd: -
}
WANT="$(norm "$MAC")"

emit() { printf '{"address":"%s"}\n' "$1"; exit 0; }

# Fast path: the address the inventory expects. True for a node that has
# already been configured, and for one booted with an `ip=` kernel argument.
# Costs one connect, so it is worth trying before waking the whole subnet.
if nc -z -G2 -w2 "$EXPECTED" 50000 2>/dev/null; then
  emit "$EXPECTED"
fi

# Slow path: populate the ARP cache with a parallel ping sweep of the /24 the
# expected address sits in, then look the MAC up.
BASE="${EXPECTED%.*}"
for i in $(seq 1 254); do
  ping -c1 -W1 -t1 "$BASE.$i" >/dev/null 2>&1 &
done
wait 2>/dev/null || true

FOUND=""
while read -r line; do
  addr="$(printf '%s' "$line" | sed -n 's/.*(\([0-9.]*\)).*/\1/p')"
  hw="$(printf '%s' "$line" | sed -n 's/.* at \([0-9a-fA-F:]*\) .*/\1/p')"
  [ -n "$addr" ] && [ -n "$hw" ] || continue
  if [ "$(norm "$hw")" = "$WANT" ]; then FOUND="$addr"; break; fi
done <<EOF
$(arp -an 2>/dev/null || true)
EOF

if [ -z "$FOUND" ]; then
  echo "no host with MAC $MAC on $BASE.0/24 — is the machine powered on, cabled, and on this LAN? (a machine in maintenance mode answers DHCP; one that is off answers nothing)" >&2
  exit 1
fi

# Confirm it is actually Talos and reachable, rather than some other device
# that happens to hold that MAC.
if ! nc -z -G2 -w2 "$FOUND" 50000 2>/dev/null; then
  echo "found MAC $MAC at $FOUND but :50000 is closed — powered on but not in maintenance mode? (Talos serves apid on 50000 in maintenance mode and in normal operation alike, so a closed port means neither)" >&2
  exit 1
fi

emit "$FOUND"

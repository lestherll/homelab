#!/usr/bin/env bash
# Stage a Talos disk image into the SSD libvirt pool.
#
# Outside Terraform because the Image Factory serves .raw.xz and
# libvirt_volume's create.content.url has no decompression step. Staging once
# also keeps `terraform apply` from re-downloading ~100MB on every rebuild —
# which matters when destroy/recreate is the development primitive.
#
# The `nocloud` image is a full pre-installed disk image, so the VM boots
# straight into maintenance mode: no ISO, no installer step, and nothing
# interactive on the console.
#
# Usage: terraform/scripts/stage-talos-image.sh <talos-version> [schematic-id]
#   e.g. terraform/scripts/stage-talos-image.sh v1.13.8

set -euo pipefail

VERSION="${1:?usage: $0 <talos-version> [schematic-id]}"

# Default schematic: qemu-guest-agent, and nothing else.
#
# The extension is not optional decoration. §8 assumes unplanned reboots on
# domestic power, and without the guest agent libvirt cannot shut the VM down
# gracefully — every host reboot becomes an unclean etcd shutdown.
#
# Minted and verified 2026-08-16 against https://factory.talos.dev/schematics
# from exactly this customization:
#
#   customization:
#     systemExtensions:
#       officialExtensions:
#         - siderolabs/qemu-guest-agent
#
# The ID is a content hash of that document, so it is stable and re-mintable:
# POSTing the same YAML always returns this same ID, which is what makes it
# safe to pin rather than treat as an opaque handle. Confirmed to serve a
# nocloud-amd64 image for v1.13.8.
#
# NOT deliberately included: the Tailscale extension. Tailscale stays on the
# host, which keeps one tailnet identity and dissolves the certSANs
# chicken-and-egg. Adding it here would be a design change, not a build tweak.
SCHEMATIC="${2:-ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515}"

# Staged through libvirt itself (vol-create-as + vol-upload) rather than by
# writing into the pool directory. The pool dir is root-owned, so a direct
# write needs sudo; going through the libvirt socket needs only libvirt group
# membership, which host_prereqs already grants. That keeps the whole Terraform
# workflow sudo-free — Ansible owns root, and nothing below it needs to.
POOL="${LIBVIRT_POOL:-homelab-ssd}"
VOL="talos-${VERSION}-nocloud-amd64.raw"
VIRSH="virsh -c qemu:///system"

if [[ -z "${SCHEMATIC}" ]]; then
  echo "empty schematic ID" >&2
  exit 1
fi

if ${VIRSH} vol-info --pool "${POOL}" "${VOL}" >/dev/null 2>&1; then
  echo "already staged: ${VOL} in pool ${POOL}"
  ${VIRSH} vol-path --pool "${POOL}" "${VOL}"
  exit 0
fi

URL="https://factory.talos.dev/image/${SCHEMATIC}/${VERSION}/nocloud-amd64.raw.xz"

echo "fetching ${URL}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL "${URL}" -o "${TMP}/image.raw.xz"
xz -d "${TMP}/image.raw.xz"

# Size the volume from the decompressed image rather than guessing. The Talos
# nocloud image is a full pre-installed disk image, so this is its real extent,
# not a minimum.
BYTES="$(stat -c %s "${TMP}/image.raw")"

# vol-create with XML rather than vol-create-as, solely to set mode 0644.
# libvirt defaults new volumes to 0600 root:root, and Terraform reads this file
# as the invoking (non-root) user to seed each system disk — being in the
# libvirt group lets you *ask libvirt* to do things, it does not let you read
# libvirt's files. Without this the apply fails with "permission denied" on a
# file that virsh will happily show you.
#
# 0644 is correct here rather than a loosening: this is a public Talos release
# artifact, byte-identical to what the Factory serves anyone. Nothing about it
# is secret. The volumes built FROM it keep libvirt's default 0600.
cat > "${TMP}/vol.xml" <<XML
<volume>
  <name>${VOL}</name>
  <capacity unit='bytes'>${BYTES}</capacity>
  <target>
    <format type='raw'/>
    <permissions>
      <mode>0644</mode>
    </permissions>
  </target>
</volume>
XML

${VIRSH} vol-create "${POOL}" "${TMP}/vol.xml"
${VIRSH} vol-upload --pool "${POOL}" "${VOL}" "${TMP}/image.raw"

DEST="$(${VIRSH} vol-path --pool "${POOL}" "${VOL}")"
echo "staged ${DEST}"
echo "matches base_image_path in terraform/clusters/<cluster>/main.tf"

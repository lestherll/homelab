# Three volumes: one disposable, two persistent. The lifecycle split is the
# whole design — see the storage section of
# docs/talos-terraform-migration-notes.md.
#
# NOTE on the 0.9.x schema: capacity/capacity_unit and target.format.type are
# the current spelling. 0.8.x's `size`/`format`/`source` arguments no longer
# exist; examples using them will not merely warn, they will fail to parse.

# --- System disk: disposable ----------------------------------------------
# A qcow2 copy-on-write overlay on the staged Talos image, so the VM boots
# straight into maintenance mode with no ISO and no installer step.
#
# Deliberately NOT lifecycle-protected. Destroying and recreating this volume
# is the point: `terraform destroy && terraform apply` giving a clean cluster
# in minutes is what turns "does the platform bootstrap from zero?" from an
# unanswerable question into a routine test, and it keeps the tier-1 recovery
# path rehearsed continuously rather than annually.
#
# WHY AN OVERLAY RATHER THAN A COPY (`create.content.url`):
# The obvious form — copy the base image into a larger volume — hits a bug in
# provider 0.9.8. `create.content` combined with an explicit `capacity` fails
# with "cannot extend file: File too large", at every size tested (5GiB and
# 20GiB, so it is the content path itself, not a size threshold). Dropping
# `capacity` succeeds but pins the volume to the content's own 4.15GiB, which
# is far too small for containerd's layers.
#
# The overlay sidesteps it and is better anyway: 20GiB capacity with 196KiB
# allocated, created in ~0s rather than by copying 4.15GiB on every rebuild —
# which matters precisely because rebuilding is meant to be routine.
#
# THE COST, stated plainly: this is the one volume that is not raw, so it
# carries qcow2's write amplification, and Talos puts etcd on it. Acceptable
# here — single-node, light write load, SSD-backed, and the disk is disposable
# by design — but if apiserver write latency ever looks wrong, moving etcd onto
# the `fast` volume is the first thing to try. `fast` and `bulk` stay raw
# specifically because they carry the latency-sensitive and bulk data.
#
# NOTE: the base image is now load-bearing at RUNTIME, not just at create time.
# It is this volume's backing file; deleting it breaks a running VM, where with
# a copy it would only have broken the next rebuild.
resource "libvirt_volume" "system" {
  name = "${var.cluster_name}-system.qcow2"
  pool = var.system_pool

  capacity      = var.system_disk_gib
  capacity_unit = "GiB"

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = var.base_image_path
    format = { type = "raw" }
  }
}

# --- Data disks: persistent -----------------------------------------------
# prevent_destroy is the mechanism that makes `terraform destroy` safe to use
# as a development primitive. Without it, the destroy/recreate loop above would
# take the platform's data with it every time.
#
# Consequence worth knowing before you hit it: `terraform destroy` on the whole
# stack will FAIL rather than skip these, and the intended workflow is to
# target the domain instead:
#     terraform destroy -target=libvirt_domain.node
# Genuinely retiring a cluster means removing the prevent_destroy block in a
# commit — deliberate, reviewable, and hard to do by accident, which is the
# entire intent.

resource "libvirt_volume" "fast" {
  name = "${var.cluster_name}-fast.raw"
  pool = var.fast_pool

  capacity      = var.fast_disk_gib
  capacity_unit = "GiB"

  # raw rather than qcow2 on purpose: this volume carries CNPG's WAL fsyncs,
  # and qcow2's write amplification would land directly on them. raw on ext4
  # is still sparse, so this costs nothing up front.
  target = {
    format = { type = "raw" }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "libvirt_volume" "bulk" {
  name = "${var.cluster_name}-bulk.raw"
  pool = var.bulk_pool

  capacity      = var.bulk_disk_gib
  capacity_unit = "GiB"

  target = {
    format = { type = "raw" }
  }

  lifecycle {
    prevent_destroy = true
  }
}

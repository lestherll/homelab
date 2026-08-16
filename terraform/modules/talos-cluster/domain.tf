# The libvirt domain.
#
# SYNTAX NOTE, because it will bite anyone reading older examples: the 0.9.x
# provider is a Plugin Framework rewrite in which os/cpu/devices/disks are
# nested ATTRIBUTES (`os = { ... }`, `disks = [ { ... } ]`), not HCL blocks
# (`os { ... }`). Every 0.8.x example on the internet uses block syntax and
# will not parse. The upside is that this file maps ~1:1 onto the domain XML,
# so `virsh dumpxml` output lines up with it directly when debugging.

locals {
  # Disk serials are the join the entire hardware-agnostic storage design rests
  # on. Talos selects volumes with a CEL expression over disk.serial (confirmed
  # available in the v1.13 UserVolumeConfig reference, 2026-08-16), so the
  # mapping from virtual disk to storage tier survives a disk being added,
  # removed or re-ordered — unlike matching on vdb/vdc enumeration order.
  #
  # Kept short: libvirt passes the serial through to QEMU, which truncates it
  # (20 chars for virtio-blk). A truncated serial still satisfies a CEL prefix
  # test but not an equality one, and that failure looks like a Talos bug
  # rather than a length limit.
  fast_serial = "fast"
  bulk_serial = "bulk"
}

resource "libvirt_domain" "node" {
  name = var.cluster_name
  type = "kvm"

  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpus

  # §8 assumes unplanned reboots on domestic power. A node that does not come
  # back after the host reboots is a cluster that does not come back.
  autostart = true
  running   = true

  # Talos boots UEFI; ovmf provides the firmware (installed by host_prereqs).
  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    loader       = "/usr/share/OVMF/OVMF_CODE_4M.fd"
    loader_type  = "pflash"
    # Yes, a string rather than a bool — the provider maps this straight onto
    # the XML attribute, which is yes/no.
    loader_readonly = "yes"
  }

  # virt-install and virt-manager set these implicitly, which is why most
  # hand-built VMs never mention them and most examples omit them. Defining a
  # domain straight from XML gets no such defaults: libvirt rejects the domain
  # outright with "UEFI requires ACPI on this architecture". apic comes along
  # for the same reason — an SMP guest without it is a guest with one usable
  # CPU.
  features = {
    acpi = true
    apic = {}
  }

  # host-passthrough exposes the real CPU's feature set to the guest. Worth it
  # on an i5-8250U: without it the guest gets a lowest-common-denominator model
  # and loses AES-NI, which containerd and etcd both notice.
  cpu = {
    mode = "host-passthrough"
  }

  devices = {
    # Graceful shutdown on host reboot depends on the guest agent being
    # reachable over this channel. Without it libvirt can only pull the plug,
    # so every host reboot becomes an unclean etcd shutdown. Needs the
    # qemu-guest-agent system extension in the Talos image — see
    # scripts/stage-talos-image.sh.
    channels = [
      {
        source = { unix = {} }
        target = {
          virt_io = { name = "org.qemu.guest_agent.0" }
        }
      },
    ]

    disks = [
      # System disk — disposable, seeded from the staged Talos image.
      {
        device = "disk"
        source = {
          file = { file = libvirt_volume.system.target.path }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        # qcow2, not raw — this is the one volume that is an overlay rather
        # than a plain image. See the long comment in volumes.tf. A mismatch
        # here does not error; qemu probes the format and boots anyway, which
        # is worse than a failure because it hides the discrepancy.
        driver = {
          name  = "qemu"
          type  = "qcow2"
          cache = "none"
          io    = "native"
        }
        boot = { order = 1 }
      },

      # fast — durable, low-latency, SSD-backed.
      #
      # cache=none + io=native keeps the guest's fsync semantics honest all the
      # way down to the physical disk. Anything cached here would let CNPG
      # believe a WAL write is durable while it sits in host page cache, which
      # is the exact failure a WAL exists to prevent.
      {
        device = "disk"
        serial = local.fast_serial
        source = {
          file = { file = libvirt_volume.fast.target.path }
        }
        target = {
          dev = "vdb"
          bus = "virtio"
        }
        driver = {
          name  = "qemu"
          type  = "raw"
          cache = "none"
          io    = "native"
        }
      },

      # bulk — durable, high-capacity, HDD-backed.
      {
        device = "disk"
        serial = local.bulk_serial
        source = {
          file = { file = libvirt_volume.bulk.target.path }
        }
        target = {
          dev = "vdc"
          bus = "virtio"
        }
        driver = {
          name  = "qemu"
          type  = "raw"
          cache = "none"
          io    = "native"
        }
      },
    ]

    interfaces = [
      {
        source = {
          network = { network = var.network_name }
        }
        mac   = { address = var.node_mac }
        model = { type = "virtio" }
      },
    ]

    # free_page_reporting lets the guest hand reclaimed pages back to the host
    # rather than holding its high-water mark forever. Not needed while this is
    # the only VM, but it is what makes a second observability-free dev VM
    # affordable later on a 15Gi box.
    mem_balloon = {
      model               = "virtio"
      free_page_reporting = "on"
    }

    # No console declared here, deliberately, and it is a real gap rather than
    # an oversight: Talos has no SSH and no shell, so when the API is
    # unreachable a serial console is the only way to see why.
    #
    # The provider marks consoles.source.pty.path as REQUIRED, but that path is
    # assigned by libvirt at domain start — there is no correct value to write.
    # Hardcoding one would be a lie that breaks on the second concurrent domain.
    # Attach out of band instead when it is actually needed:
    #     virsh console <cluster_name>
    # Revisit if a later provider release makes pty.path optional.
  }
}

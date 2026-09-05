# docs/ index

Every doc in this tree, one line each, so a reader can find the right one
without opening all of them. Docs here describe the system **as it is now**;
history and past-tense engineering learnings belong in `journal/` instead —
if you're tempted to add a "what we tried" narrative to one of these, it
probably belongs there.

For the product pitch, see `CONCEPT.md` at the repo root — it's a short
concept doc now, not a decision log (the prior numbered D-log is in git
history). `docs/adr/` holds standalone decision records going forward. The
pages below are the long-form detail behind specific decisions or the
operating reference for a specific area.

## Platform API and app onboarding

- [`platform-api-usage.md`](platform-api-usage.md) — field reference for
  onboarding or migrating an app onto `Database`/`ObjectStorage`/`Application`.
- [`self-service-platform-design-notes.md`](self-service-platform-design-notes.md) —
  why the self-service platform API is shaped the way it is: kro, the resource-API/
  attachment-API split, the one-way-door choices.
- [`zero-touch-app-registration.md`](zero-touch-app-registration.md) — how an
  app repo registers itself with the platform: the identity chain, the
  workflow an app adds, the isolation test matrix.
- [`identity-headers.md`](identity-headers.md) — the app-side contract for
  Tailscale's `Tailscale-User-*` headers, and when they're absent.
- [`gitops-onboarding-learnings.md`](gitops-onboarding-learnings.md) — what
  hand-built app/data-service instances taught before the self-service platform API; superseded for
  `Database`/`ObjectStorage`/`Application` themselves, still relevant for
  anything not yet on the typed API.
- [`message-broker-design-notes.md`](message-broker-design-notes.md) —
  exploratory notes on a possible future message-broker data service. Not
  built, not scheduled.
- [`external-consumer-access-notes.md`](external-consumer-access-notes.md) —
  investigation into apps hosted *off* the platform consuming `Database`/
  `ObjectStorage` over the tailnet. Nothing built; records what was verified.

## Storage and networking

- [`storage-tiering-notes.md`](storage-tiering-notes.md) — why there are two
  storage tiers, what belongs on each, the PVC-migration runbook. Naming and
  provisioner mechanics predate the Talos rewrite; see the header note.
- [`networkpolicy-enforcement-notes.md`](networkpolicy-enforcement-notes.md) —
  why `infrastructure/cilium/` exists, the CNI-chaining mechanism and its
  traps, the enforcement test.

## The Talos/Terraform platform

- [`talos-terraform-migration-notes.md`](talos-terraform-migration-notes.md) —
  why the platform runs on a Terraform-provisioned Talos VM instead of
  bare-metal Ansible/k3s, and the storage-role design that came out of it.
  Executed 2026-08-16; operating manual is `terraform/README.md`.
- [`talos-cutover-runbook.md`](talos-cutover-runbook.md) — the executed
  procedure for the k3s → Talos cutover. Kept as the rehearsal script for a
  rebuild.

## Fleet — current

- [`fleet/inventory-and-provisioning-approach.md`](fleet/inventory-and-provisioning-approach.md) —
  the recommended approach to machine inventory. The hand-written-node-list
  half is built (`fleet/nodes.yaml`); the Node Feature Discovery half is not.
- [`fleet/fleet-provisioning-design-notes.md`](fleet/fleet-provisioning-design-notes.md) —
  design for making machine addition repeatable across the fleet's two
  machine models (Ubuntu hypervisor, bare-metal Talos). Partly executed —
  read its status header.
- [`fleet/headless-ubuntu.md`](fleet/headless-ubuntu.md) — building an
  autoinstall ISO and installing Ubuntu unattended, including the
  install-time NOPASSWD sudoers drop-in Ansible needs.
- [`fleet/headless-talos-install.md`](fleet/headless-talos-install.md) —
  installing Talos on a machine with no video output, driven from a Mac.
- [`fleet/talosctl-off-lan.md`](fleet/talosctl-off-lan.md) — how `talosctl`
  reaches a node from off the LAN via the node's own Tailscale system
  extension. Built and verified.

## Fleet — the bare-metal fleet migration (multi-node)

The ADR is **accepted, build in progress**: `clusters/homelab-metal/`,
`terraform/modules/talos-metal/` and `infrastructure/longhorn/` are real,
machine 2 is built, machine 1's cutover is still ahead. See the Description
at the top of `AGENT.md` for the current split. This group's status headers
were reconciled against that reality on 2026-09-04 — each now says built,
resolved, partially-built, or still-design/rejected as accurate, so "not
built" can be trusted on sight again below:

- [`fleet/golden-architecture.md`](fleet/golden-architecture.md) — the
  three-layer (Platform API / Infrastructure / Fleet) model the rest of this
  group is written against. Standing description, current.
- [`fleet/target-architecture.md`](fleet/target-architecture.md) — the
  detailed build-out of the Fleet and Infrastructure layers under the fleet migration.
  Partially built: several N=1 pieces landed, the N=3/HA shape is still ahead.
- [`fleet/platform-api-migration-impact.md`](fleet/platform-api-migration-impact.md) — what
  the fleet migration costs the Platform API layer. The three Longhorn-cutover breakages it
  found are resolved; the N=3/multi-cluster prep items are still ahead.
- [`fleet/hardware-fit-notes.md`](fleet/hardware-fit-notes.md) — the actual
  measured hardware (two mismatched machines, no BMC) versus what the design
  assumed. Now encoded in `fleet/nodes.yaml`.
- [`fleet/multi-node-ha-design-notes.md`](fleet/multi-node-ha-design-notes.md) —
  earlier design notes on adding machines and control-plane HA. Still design —
  genuinely not built until a third machine exists.
- [`fleet/fleet-control-plane-survey.md`](fleet/fleet-control-plane-survey.md) —
  survey of how other systems build a unified API over owned machines. Survey,
  not a decision; still accurate.
- [`fleet/metal3-investigation.md`](fleet/metal3-investigation.md) — why
  Metal³ was rejected (BMC-gated; can't deliver a Talos config). Settled.
- [`fleet/tinkerbell-investigation.md`](fleet/tinkerbell-investigation.md) —
  why Tinkerbell is the right project but the wrong time (netboot deferred).
  Settled, still deferred.
- [`fleet/talos-without-omni.md`](fleet/talos-without-omni.md) — vendor-
  dependency audit of running Talos without Omni. Settled: not needed.
- [`fleet/smart-plug-power-control.md`](fleet/smart-plug-power-control.md) —
  whether a smart plug can drive Tinkerbell's BMC layer directly. Still open,
  per the ADR's "remote power" row.
- [`fleet/cilium-only-networking.md`](fleet/cilium-only-networking.md) —
  whether Cilium alone (no Flannel chaining) works under the fleet migration's bridged
  networking. **Adopted, built** — live on `clusters/homelab-metal/`.
- [`fleet/provisioning-automation-without-netboot.md`](fleet/provisioning-automation-without-netboot.md) —
  what's left to automate given manual install and NFD, and whether it's
  worth it. Mostly adopted: machine-config apply and disk tag/zone labeling
  are built; netboot itself stays deferred.

## Journal and ADRs

- [`journal/`](journal/README.md) — dated, concise engineering-decision
  entries: what broke or was needed, what was found, what was decided. This
  is where past-tense history belongs; see its README for the template.
- [`adr/`](adr/0001-single-model-talos-fleet.md) — architecture decision
  records. Being reorganized separately; not covered by this index's
  maintenance rules yet.

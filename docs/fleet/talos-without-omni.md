# Is plain Talos enough? A vendor-dependency audit

**Status: audit, 2026-08-30.** Written to check the position *"Omni may make
things easier but I don't want to be vendor locked — Talos should be enough."*
Companion to `docs/fleet/fleet-control-plane-survey.md` and to
`docs/adr/0001-single-model-talos-fleet.md` §8.3. Two of its recommendations are
concrete changes; the rest is recording what is already true.

**The finding, up front: the position is correct on the merits, and the vendor
dependency worth worrying about is not Omni.** This cluster already calls two
Sidero-hosted services, neither recorded anywhere in the repo, and one of them
has a *worse* licence than Omni does.

---

## 1. What Omni actually adds, and what already covers it here

| Omni capability | What covers it here | Gap at N=3 |
| --- | --- | --- |
| Machine registration/discovery over WireGuard (SideroLink) | `talos_machine_configuration_apply` against a known IP; every machine on one LAN | none — real only for machines in other locations or behind NAT, of which this fleet has none |
| Highly-available Kubernetes API endpoint | Talos VIP, already scheduled as LES-151 in ADR §4.1 | none |
| Cluster templates, machine classes | `terraform/modules/talos-cluster/` plus `for_each` — that *is* a cluster template, in a language already in use | none |
| Per-machine and per-group config patches | `config_patches` in `talos.tf`, already a list | none. Note Omni is arguably *behind* here: siderolabs/omni#2593 records that per-machine patches are stripped by `omnictl template sync` with no way to express them in the template |
| OS and Kubernetes upgrades | `talosctl upgrade --image ghcr.io/siderolabs/installer:<ver>` and `talosctl upgrade-k8s --to <ver>` | orchestration across machines is manual. At N=3 that is three commands |
| etcd backup | `talosctl etcd snapshot` | scheduling it. That is a CronJob, not a product |
| Identity/RBAC in front of kubeconfig | already built, and more tightly integrated than Omni's: the apiserver's multi-issuer `AuthenticationConfiguration` plus `infrastructure/human-auth/rbac.yaml`, reached over the tailnet | none |
| Encrypted node-to-node traffic | one LAN today; KubeSpan or Cilium if ever needed | none |
| Workload proxying / UI | `tailscale-operator`, per-`Application` | none |

**Read the "gap" column: at N=3 on one LAN, Omni's value is concentrated in the
two things this fleet doesn't have** — machines in disparate physical locations,
and a team needing a UI with its own RBAC. Talos plus what is already built
covers the rest.

Where Omni would start to earn its place: more than one physical site (SideroLink
is the genuinely hard-to-replicate piece), or enough machines that upgrade
orchestration stops being three commands. Neither is near.

## 2. The lock-in question, answered by licence rather than by feeling

Four Sidero artifacts, three licences:

| Component | Licence | Additional Use Grant | Used here today? |
| --- | --- | --- | --- |
| **Talos Linux** | **MPL-2.0** | n/a — open source | **yes — the OS** |
| **Image Factory** (`siderolabs/image-factory`) | **MPL-2.0** | n/a — open source | **yes — the hosted instance** |
| Omni | BUSL 1.1 → MPL-2.0 on 2030-08-04 | *"personal use in a home lab environment"* | no |
| **Discovery Service** | BUSL 1.1 → MPL-2.0 on 2030-07-22 | **"None"** | **yes — the hosted instance, by default** |

Two things fall out, both counter-intuitive.

**Talos itself is MPL-2.0, and that is most of the answer.** The OS this whole
platform stands on is under a standard open-source licence — no change date, no
use grant to re-read, forkable if Sidero disappeared. ADR §9 says *"Talos is
single-vendor"* and treats that as one undifferentiated bet. It isn't: it is a
bet on a **vendor's roadmap and support**, not on a **licence**. Omni is the
opposite — a bet on a licence and a service. §9 should separate them, because
they fail in different ways and only one of them is recoverable by forking.

**But two hosted Sidero services are already in the critical path, unrecorded.**

### 2.1 `factory.talos.dev` — recorded in code, benign, about to get load-bearing

`terraform/scripts/stage-talos-image.sh:64` fetches
`https://factory.talos.dev/image/${SCHEMATIC}/${VERSION}/nocloud-amd64.raw.xz`.
That is a hosted instance of an **MPL-2.0** project, so the dependency is on
someone's *uptime*, not on their *licence* — a materially weaker form of
lock-in.

ADR §8.1 makes it heavier, though: Longhorn's two system extensions turn the
schematic from today's *"qemu-guest-agent, and nothing else"* into something the
cluster's **storage** depends on.

The escape hatch is good. `ghcr.io/siderolabs/imager` is the same code the
Factory runs, usable locally with `--system-extension-image`, and it is strictly
*more* capable — the Factory serves only official releases and official
extensions, while imager takes arbitrary ones. So the exit is a script change,
not a migration. Worth taking when §8.1 lands, not because the Factory is
untrustworthy but because the artifact your storage depends on shouldn't require
someone else's service to rebuild.

### 2.2 `discovery.talos.dev` — nobody chose it, and it has the licence problem

`terraform/modules/talos-cluster/talos.tf` sets no `cluster.discovery` block, so
the cluster runs Talos defaults: **the service registry is enabled**, pointed at
`https://discovery.talos.dev/`. This was not a decision. It is a default nobody
has looked at.

The privacy half is genuinely fine, and Sidero documents it precisely: *"Data is
encrypted by Talos Linux before being sent to the discovery service, and it can
only be decrypted by the cluster members… The discovery service does not have the
encryption key."* It sees a cluster ID, a client version, an affiliate count, and
ciphertext.

The **licence** half is the finding. The docs note the service *"may, with a
commercial license, be operated by your organization"*, and the repository's
LICENSE is BUSL 1.1 with **Additional Use Grant: "None"**, Change Date
2030-07-22.

> **The self-hosting escape hatch for the discovery service is licensed more
> restrictively than Omni is.** Omni's BUSL explicitly grants home-lab use. The
> discovery service's grants nothing at all. If the concern is *"don't depend on
> something I can't run myself"*, this is the sharpest instance of it in the
> current design — and the only one that arrived by default rather than by
> choice.

**The fix is not to self-host it. It is to turn it off.** At N=1, and at N=3 on
one LAN with static addressing, the service registry buys nothing: it exists so
members can find each other across networks, and it is a hard requirement only
for KubeSpan, which this design does not use.

```yaml
cluster:
  discovery:
    enabled: false
```

The `kubernetes` registry is **not** a fallback — it is deprecated and disabled
by default, because Kubernetes 1.32+ restricts Node read access in a way that
breaks it.

**This belongs in ADR §4.1's rebuild list, beside `certSANs`.** It is a
machine-config change, AGENT.md already records that bootstrap-adjacent
machine-config changes do not land in place, and a rebuild is already scheduled.

## 3. What lock-in would actually look like, so it can be recognised

Licences are the visible part; the useful test is *direction of ownership*.
Three questions, applied to both designs:

1. **Who holds the PKI?** Today: you do — SOPS-encrypted, and deliberately twice
   (`terraform/clusters/homelab/talos-secrets.sops.yaml` in talosctl's spelling,
   alongside the Terraform copy), with AGENT.md documenting how to rebuild a
   working `talosconfig` from it with no vendor in the loop. Under Omni: Omni
   brokers access and issues short-lived credentials. **This is the single
   biggest difference, and the thing to protect.**
2. **Who owns the machine config?** Today: `talos.tf`, in git, diffable. Under
   Omni: Omni, with config patches as Omni resources. Note that `omnictl cluster
   import` is still an open issue (siderolabs/omni#1315) — the *entry* path is
   unfinished, which is a fair signal about how well-trodden the *exit* is.
3. **Can the cluster be rebuilt with the vendor unreachable?** Today: not quite —
   a cold rebuild currently needs `factory.talos.dev`. Closing §2.1 makes the
   answer yes. Under Omni: no, machines take their config from Omni.

On all three the current design is in good shape, and the two gaps are small and
closeable now.

## 4. Recommendation

1. **Disable the discovery service registry.** One machine-config block, folded
   into ADR §4.1's rebuild. Unchosen default, worst licence in the stack, zero
   benefit at this scale.
2. **Move image building to `imager`** when §8.1's Longhorn extensions land.
   Same code, no hosted dependency, and it removes the only remaining external
   requirement for a cold rebuild.
3. **Record both in AGENT.md.** *"Which external services does a cold rebuild
   need"* is precisely the kind of fact that is invisible right up until the
   rebuild.
4. **Leave Omni alone, and split ADR §9's Talos bet in two.** Talos-the-OS is
   MPL-2.0 and forkable; Omni-the-service is BUSL and is not. §9's *"Talos is
   single-vendor"* is true about roadmap and support and false about licence, and
   the distinction changes what the risk actually is.
5. **Do not self-host the discovery service.** Turning it off is free and
   licensed. Running it is neither.

---

## Sources

- [Talos Linux LICENSE (MPL-2.0)](https://github.com/siderolabs/talos/blob/main/LICENSE)
- [Image Factory LICENSE (MPL-2.0)](https://github.com/siderolabs/image-factory/blob/main/LICENSE)
- [Discovery Service LICENSE (BUSL 1.1, Additional Use Grant "None")](https://github.com/siderolabs/discovery-service/blob/main/LICENSE)
- [Omni LICENSE (BUSL 1.1, home-lab use grant)](https://github.com/siderolabs/omni/blob/main/LICENSE)
- [Talos — Discovery Service](https://docs.siderolabs.com/talos/v1.11/configure-your-talos-cluster/system-configuration/discovery)
- [Talos — Boot Assets / imager](https://www.talos.dev/v1.10/talos-guides/install/boot-assets/)
- [siderolabs/omni#1315 — `omnictl cluster import`](https://github.com/siderolabs/omni/issues/1315)
- [siderolabs/omni#2593 — config patches in cluster templates](https://github.com/siderolabs/omni/issues/2593)

# Smart-plug power control — Tinkerbell drives one natively, no virtual BMC

**Status: research, 2026-09-01. Nothing built.** Answers "could a Tapo power strip
plus a virtual BMC make Metal³ or Tinkerbell work?"

**The question assumed a virtual BMC. It turns out not to need one.**

- **Tinkerbell: yes.** Rufio, its BMC layer, already ships a generic signed-webhook
  provider. A smart plug is wired in with a small shim and no BMC emulation.
- **Metal³: no**, and for a reason unrelated to power — so the plug does not move
  its verdict.
- **Machine 1 is unaffected.** It is a laptop; a plug cuts its charger, not its
  power (`hardware-fit-notes.md` §3). This is a machine-2-and-later answer.

> ### Correction
>
> `tinkerbell-investigation.md` §7 said *"Rufio speaks Redfish/IPMI/AMT, not smart
> plugs, so the plug stays outside Tinkerbell's control loop."* **That was wrong**,
> and the same claim was propagated into `fleet-control-plane-survey.md` §7. It
> came from reading the `ProviderName` enum in
> `api/v1alpha2/tinkerbell/bmc/provider.go` instead of the providers Rufio
> actually wires up. Both are corrected; this document is the replacement.

---

## 1. What Rufio actually supports

Read in the `tinkerbell/tinkerbell` source, not the docs:

| Finding | Where |
| --- | --- |
| Rufio wires up an **`rpc`** provider (generic HMAC-signed webhook) and a **`homeassistant`** provider, alongside the IPMI/Redfish/AMT ones | `rufio/internal/controller/client.go` imports `bmclib/v2/providers/rpc` and `.../providers/homeassistant` |
| Both are first-class on the `Machine` CRD | `api/v1alpha1/bmc/machine.go` — `RPC *RPCOptions`, `HomeAssistant *HomeAssistantOptions` |
| The webhook is configurable end to end | `RPCOptions{ConsumerURL, Request{HTTPMethod, HTTPContentType, StaticHeaders, TimestampHeader}, Signature{HeaderName…}, HMAC}`; defaults `X-Rufio-Timestamp` / `X-Rufio-Signature` |
| The Home Assistant option is literally a switch entity | `HomeAssistantOptions{SwitchEntityID, PowerOperationDelaySeconds}` |

That second provider is the tell: **Tinkerbell already treats "a smart switch" as
a legitimate power interface.** This is the MAAS webhook-driver trick the survey
admired, except built in rather than bolted on.

## 2. Power-only is a supported shape

A plug can answer "on/off/status" and nothing else. That is enough, and the API
says so:

- **Every field of a BMC task action is an optional pointer** —
  `api/v1alpha1/bmc/task.go`'s `Action` has `PowerAction`, `BootDevice`,
  `OneTimeBootDeviceAction` and `VirtualMediaAction`, all `omitempty`. **A task
  may contain only a power action.**
- **`bootMode: customboot` takes arbitrary action lists** —
  `preparingActions` / `postActions` (Tinkerbell's own `docs/technical/BOOT_MODES.md`), so a
  workflow can be `powerAction: off` → `powerAction: on` and nothing else.
- **`bootMode: netboot` will not work** — it always emits an
  `oneTimeBootDeviceAction`, which no plug can serve. Use `customboot`.

### The one precondition

Nothing in this path can set a boot device, so **each machine's BIOS boot order
must be permanently PXE-first, disk-second.** Tinkerbell's per-MAC iPXE script
then decides netboot-versus-local-disk. That is the normal arrangement for
netbooted fleets, and it is what makes a power-only interface sufficient rather
than crippled.

## 3. The hardware

The **Tapo P304M** fits, on the specifics that matter:

- **Four individually controlled outlets** — one per machine, which is the whole
  requirement. A single-relay strip would be useless.
- **Per-outlet energy monitoring.**
- **Local control without the cloud** — `python-kasa` supports the P304M over
  KLAP with child-device (per-socket) control. Matter is also supported, but the
  local vendor API is the shorter path for a shim.

## 4. The shim

```
  Rufio Machine (CRD)                    your shim                  the strip
  ─────────────────────                  ─────────                  ─────────
  providerOptions:                                                          
    rpc:                    HMAC-signed                python-kasa           
      consumerURL: ──────▶  HTTP POST   ──────▶  set outlet 2 on/off ──▶ P304M
        http://shim/power                                                   
```

Roughly a hundred lines: verify Rufio's HMAC signature, map machine → outlet,
call `python-kasa`, return the power state. **Rufio does the signing** — that is
configuration, not something to invent.

> **Not verified, and the one thing to check first:** the exact JSON request and
> response schema bmclib's `rpc` provider sends and expects. Read
> `github.com/bmc-toolbox/bmclib/v2/providers/rpc` before writing anything. A
> shim written against a guessed schema is the way this goes wrong.

### Why not the `homeassistant` provider

It needs zero code — each P304M socket already appears in Home Assistant as a
switch entity, so it is an entity ID and a long-lived token. But it means running
and maintaining Home Assistant, which is a large service to adopt in service of
one power button. Against the stated goal of maintaining fewer things, a hundred
lines in one container beats a smart-home platform. Revisit only if Home
Assistant arrives here for its own reasons.

## 5. Why Metal³ is still out

Not a power problem. Two blockers, and the second is decisive on its own:

1. **BMO's driver list is closed** — `pkg/hardwareutils/bmc/` registers IPMI and
   Redfish variants only. There is no webhook entry point, so the shim would have
   to be a real Redfish server rather than an HTTP handler. `sushy-tools` is the
   honest starting point (8 abstract driver methods, and a `minimum` feature set
   that trims what must be implemented) — but that is BMC emulation, which is
   precisely the work Tinkerbell does not require.
2. **The Talos config-drive blocker is untouched.** Metal³ configures machines
   through a cloud-init/Ignition config drive; Talos reads only `talos.config=`
   or a `metal-iso` volume. `metal3-investigation.md` §6 established this as an
   *independent* reason for rejection, and no amount of BMC fixes it.

So a virtual BMC would buy Metal³ the first half of an integration whose second
half does not exist.

## 6. Scope, and what it changes

**Machine 2 and any later machine.** Not machine 1 — a plug cannot power-cycle a
laptop with a charged battery, and that is the machine currently running
everything.

This does not make remote power urgent. It removes the objection that a plug
would sit outside Tinkerbell's control loop, which means **the purchase is not
stranded on future software work**: buy the strip when convenient, and the
integration path exists whenever netboot arrives.

## 7. Recorded, not scheduled: the energy monitoring is a real finding

AGENT.md records that `node-exporter` measures the VM, `/sys/class/powercap` is
empty inside it, and the RAPL series behind
`infrastructure/observability/dashboards/power-energy.json` therefore have **no
source** — those panels are dark, and reconnecting them means an exporter on the
host (LES-97).

**A plug reporting watts per outlet is a different and arguably better source**:
it measures the wall, not the package, so it captures disks, fans and PSU losses
that RAPL never sees, and it survives the machine being a VM host, bare metal, or
off. It does not fit the existing dashboard's metric names, so this is a new
panel rather than a repair.

Worth knowing before buying — it makes the strip do two jobs. Not part of any
current plan.

---

## Related

- `docs/fleet/tinkerbell-investigation.md` — Tinkerbell's overall verdict; §7's
  split trigger, whose second half this answers
- `docs/fleet/metal3-investigation.md` §6 — the Talos config-drive blocker
- `docs/fleet/hardware-fit-notes.md` §3 — why machine 1 is out of scope
- `docs/adr/0001-single-model-talos-fleet.md` §8.4 — netboot staged, power open

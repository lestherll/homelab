# Handoff — next session

Working file, not repo content. Delete when the cutover is done.

## Where things stand

- **Talos VM running** at `10.10.0.10`, node `talos-cp-01`, v1.13.8 / k8s 1.36.2.
  Built by `terraform apply`. Cluster is **empty** — Flux has never been pointed
  at it.
- **k3s is still running** and still serving the four tailnet ingresses. Nothing
  has been cut over yet.
- **Branch `feat/talos-cutover-infra`** (local, unpushed, 7 commits ahead of
  `main`) holds every `infrastructure/` change the new cluster needs. `main` has
  `ansible/`, `terraform/` and `docs/`.

## Run these first — they need a TTY (sudo is not passwordless here)

**1. Stop k3s.** Takes down grafana, alertmanager, fastapi-echo and
personal-finance-dashboard. Data on disk is untouched and this is reversible
with `systemctl start k3s`.

```bash
sudo systemctl stop k3s && sudo systemctl disable k3s
```

**2. Give the VM the machine.** Only after step 1 — the host has 15Gi and the
VM now asks for 12Gi. Already planned: **0 to add, 2 to change, 0 to destroy**
(domain resize in place, plus the `rotate-server-certificates` machine-config
patch). No rebuild, data disks untouched.

```bash
cd terraform/clusters/homelab
export TF_VAR_machine_secrets="$(sops --decrypt --output-type json machine-secrets.sops.json)"
sg libvirt -c "terraform apply"
```

The domain needs a power cycle to actually take the new memory. Confirm with
`sg libvirt -c "virsh dominfo homelab"` and check the node returns:

```bash
talosctl --talosconfig /tmp/talos/talosconfig -n 10.10.0.10 -e 10.10.0.10 health
```

**3. Converge the host** (idempotency is still unconfirmed; this also installs
kubectl, which the host loses when k3s goes):

```bash
sudo ansible-playbook -i ansible/inventory/hosts.ini \
  ansible/playbooks/converge.yml --tags host_prereqs,bulk_storage,cli_tools
```

Expect `changed=0` on a second run. Not `heartbeat_watchdog` — it hard-fails
until a real `ntfy_topic` replaces the placeholder in `hosts.ini`.

## Getting access

```bash
sops --decrypt terraform/clusters/homelab/talos-secrets.sops.yaml > /tmp/ts.yaml
mkdir -p /tmp/talos && (cd /tmp/talos && talosctl gen config homelab https://10.10.0.10:6443 --with-secrets /tmp/ts.yaml -o .)
talosctl --talosconfig /tmp/talos/talosconfig -n 10.10.0.10 -e 10.10.0.10 kubeconfig /tmp/kubeconfig
```

Group membership needs a fresh login; until then prefix libvirt commands with
`sg libvirt -c "..."`.

## Then: LES-96, the cutover

The runbook in `docs/talos-terraform-migration-notes.md` is **written for the
rejected bare-metal alternative** and must not be followed as-is. It says to
re-image the host, calls "does Talos mount a populated ext4 disk without
reformatting" the biggest unknown (moot — data moves by dump/restore into new
virtual disks), tells you to verify RAPL (which cannot work in a guest), and
says to delete `bulk_storage` (still needed for the HDD pool). **Write the
VM-shaped runbook first.** Roughly:

1. Dump and verify: `pg_dump` every CNPG database, `aws s3 sync` every bucket
   out over the tailnet. These dumps are the only safety net — there is no
   second machine.
2. Merge `feat/talos-cutover-infra` to `main`. It cannot land before this point:
   it repoints storage at guest-only paths and breaks `Application.persistence`.
3. Bootstrap Flux against the Talos cluster. Terraform deliberately stops at an
   empty cluster.
4. Restore: instances re-create empty → `pg_restore` → `s3 sync` back.
5. Verify all four ingresses serve TLS. Expect ~4 fresh Let's Encrypt
   issuances; prune the stale `ts-*` devices in the tailnet admin console.

## Blocking or adjacent

- **LES-68 — no backups exist.** The runbook leans on verified dumps as the
  safety net, which is exactly what this issue says does not exist. Worth
  closing properly rather than hand-dumping once.
- **LES-98 — the watchdog.** The last forced change still unbuilt. It proves
  the host is alive, which after cutover says little about the VM.
- **personal-finance-dashboard's own repo** must drop `persistence.hostPath`
  or its `Application` will not reconcile. Its host-side CLI dies with it.
- **LES-97** — power dashboards go dark; accepted, not a bug to chase.
- **LES-99 / LES-101 / LES-100 / LES-102** — post-cutover tidy-up, decision
  record, cold-apply test, sparse-image overcommit alert.

## Traps — do not rediscover

- **The VM subnet must miss the Kubernetes service CIDR.** `10.100.0.0/24` sits
  inside `10.96.0.0/12`. Symptom is etcd stuck on "Waiting for etcd spec" with
  no stated cause; the reason appears only in `talosctl dmesg | grep diagnostic`.
  Now `10.10.0.0/24`.
- **Talos enforces PodSecurity `baseline`**, which forbids `hostPath`. The
  storage provisioners' helper pods need it, hence `enforce: privileged` on the
  `storage` namespace — it fails at the *first PVC*, not at deploy.
- **`machine.certSANs` omission fails as a hang, not an error.**
- **libvirt provider 0.9.x uses nested attributes, not blocks.**
- **`terraform destroy` refuses** while the data volumes exist. Rebuild with
  `-target=module.cluster.libvirt_domain.node -target=module.cluster.libvirt_volume.system`.
- **Check `git log origin/main..<branch>`, not the PR list.** The last stack
  merged into its own base branch and read as merged while `main` had none of it.

# Handoff — next session

Working file, not repo content. Delete when the cutover is done.

## State

- **Talos VM running**, `10.10.0.10`, node `talos-cp-01` Ready, **8 vCPU / 12Gi**,
  Talos v1.13.8 / k8s v1.36.2. Cluster is **empty** — Flux not installed.
- **k3s stopped and disabled.** Data untouched on disk. Nothing is serving; all
  four tailnet ingresses are dark. That is the expected middle of the cutover.
- **`feat/talos-cutover-infra`** — local, unpushed, 9 commits ahead of `main`.
  Holds every `infrastructure/` change the new cluster needs. Must not merge
  before step 2 of the runbook.
- A Pending `kubernetes.io/kubelet-serving` CSR is **correct** — the approver
  ships with metrics-server on the branch and will clear it.

## Next: LES-96, the cutover

Follow **`docs/talos-cutover-runbook.md`**. It is written for this design and
grounded in the measured data. The runbook inside
`talos-terraform-migration-notes.md` is the rejected bare-metal plan's and is
now marked superseded.

The constraint that drives its ordering: **the VM and k3s cannot both run**
(12Gi + ~7Gi > 15Gi), and the data is only reachable through k3s — so dumps are
taken with the VM shut down, then the VM comes back for the restore.

Shape: bring k3s back briefly → dump and verify → stop k3s, start VM → merge the
branch → bootstrap Flux (**create the `sops-age` secret or nothing decrypts**) →
restore → verify.

Rollback is clean up to the Flux bootstrap and a rebuild after it. Do not start
step 2 on unverified dumps.

## Regenerating access (both live in /tmp and will be gone)

```bash
cd ~/projects/homelab
sops --decrypt terraform/clusters/homelab/talos-secrets.sops.yaml > /tmp/ts.yaml
mkdir -p /tmp/talos && (cd /tmp/talos && talosctl gen config homelab https://10.10.0.10:6443 --with-secrets /tmp/ts.yaml -o . --force)
talosctl --talosconfig /tmp/talos/talosconfig -n 10.10.0.10 -e 10.10.0.10 kubeconfig /tmp/kubeconfig --force
```

Prefix libvirt commands with `sg libvirt -c "..."` until a fresh login picks up
the group. `sudo` needs a TTY.

## Adjacent

- **LES-68 — no backups.** The runbook hand-carries the data once; the next
  rebuild has nothing. Immediate follow-up, not a later nicety.
- **LES-98 — watchdog.** Last unbuilt forced change; proves the host is alive,
  which now says little about the VM.
- **personal-finance-dashboard's repo** must drop `persistence.hostPath` before
  its `Application` will reconcile. Host-side CLI dies with it.
- **LES-97** — power dashboards dark in a guest. Accepted, not a bug.
- **LES-99 / 100 / 101 / 102** — post-cutover reclaim, cold-apply test, decision
  record, sparse-image overcommit alert.

## Traps

- **Don't use `talosctl health`** — it hangs on a single-node cluster with
  nothing deployed. Use `talosctl services` + `kubectl get nodes`.
- **VM subnet must miss the service CIDR.** `10.100.0.0/24` is inside
  `10.96.0.0/12`; symptom is etcd stuck on "Waiting for etcd spec", visible only
  in `talosctl dmesg | grep diagnostic`. Now `10.10.0.0/24`.
- **Talos enforces PodSecurity `baseline`**, which forbids `hostPath`. The
  storage provisioners' helper pods need `enforce: privileged` on the `storage`
  namespace — it fails at the *first PVC*, not at deploy.
- **`terraform destroy` refuses** while data volumes exist. Rebuild with
  `-target=module.cluster.libvirt_domain.node -target=module.cluster.libvirt_volume.system`.
- **Check `git log origin/main..<branch>`, not the PR list** — the last stack
  merged into its own base branch and read as merged while `main` had none of it.
- **Recreating a Tailscale exposure burns a cert.** Expect ~4 fresh LE issuances
  at cutover; never retry in a loop (five failures/hour trips a rate limit that
  each attempt extends).

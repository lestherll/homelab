# Cutover runbook — k3s to the Talos VM

Written 2026-08-16, for the **virtualised** design that was actually built.

> The runbook under `# Alternative A` in `talos-terraform-migration-notes.md` is
> for the *rejected* bare-metal plan. Do not follow it. It tells you to re-image
> the host, names "does Talos mount a populated ext4 disk without reformatting"
> as the biggest unknown (moot — data moves by dump and restore into new virtual
> disks), asks you to verify RAPL (impossible inside a guest), and says to delete
> the `bulk_storage` role (still needed, it owns the HDD libvirt pool).

## The constraint that shapes everything

**The VM and k3s cannot run at the same time.** The host has 15Gi; the VM is
sized 8 vCPU / 12Gi. k3s needed ~7Gi. Whichever you want running, the other must
be down.

This matters because the data you are migrating is only reachable *through*
k3s — a CNPG dump needs Postgres running, a bucket export needs SeaweedFS
running. So the dump phase runs with the VM shut down, and only then does the
VM come back for the restore. Plan for the platform to be fully dark in
between; there is no window where both clusters serve.

## State this assumes

- Talos VM `homelab` running at `10.10.0.10`, node `talos-cp-01` Ready,
  8 vCPU / 12Gi. Cluster **empty** — no Flux.
- k3s `inactive` and `disabled`, its data untouched on disk.
- `feat/talos-cutover-infra` merged to `main` — or ready to be. It carries the
  storage rewrite, metrics-server and the `Application.persistence` change, and
  **must not** land before step 3.
- Nothing is currently serving. The four tailnet ingresses are already dark.

## What actually needs moving

Measured 2026-08-16, and it is far less than the plan assumed:

| Data | Where it lives now | Size |
|---|---|---|
| CNPG Postgres volumes | `/var/lib/rancher/k3s/storage/` (SSD) | small |
| SeaweedFS buckets | `/mnt/storage/k8s-volumes/` (HDD) | `/mnt/storage` holds 2.1G total, of which ~2.07G is the VM's own bulk image — so the buckets are **effectively empty** |
| personal-finance-dashboard data | `/home/lestherll/projects/personal-finance-dashboard/data` | 8.3M |

Confirm before trusting this — the directories are root-owned:

```bash
sudo du -sh /var/lib/rancher/k3s/storage/* /mnt/storage/k8s-volumes/*
```

If the buckets really are empty, step 1's `s3 sync` is a no-op and you can skip
it. Decide that from the measurement, not from this table.

---

## Step 0 — Bring k3s back up to read from it

```bash
sg libvirt -c "virsh shutdown homelab"          # graceful; qemu-guest-agent is running
sg libvirt -c "virsh domstate homelab"          # wait for "shut off"
sudo systemctl start k3s                        # still disabled: this does not survive reboot
KUBECONFIG=~/.kube/config kubectl get nodes
```

Give Flux a moment, then **suspend it** — you do not want it reconciling
`main` into a cluster you are about to abandon, and `main` no longer describes
k3s:

```bash
KUBECONFIG=~/.kube/config flux suspend kustomization --all
```

Enumerate what exists rather than trusting any list in this repo — the
`Database`/`ObjectStorage` instances are declared in the *app* repos:

```bash
KUBECONFIG=~/.kube/config kubectl get databases,objectstorages,applications -A
KUBECONFIG=~/.kube/config kubectl get pvc -A
```

## Step 1 — Dump, and verify the dumps

These dumps are the entire safety net. There is no second machine, and once the
new cluster provisions fresh volumes the old ones are only recoverable by hand
from disk. Write them **off** `/` and `/mnt/storage` if you have external media;
otherwise `~/cutover-dumps/` is acceptable given the sizes involved.

```bash
mkdir -p ~/cutover-dumps && cd ~/cutover-dumps
```

**Postgres** — per `Database` instance, via the CNPG plugin:

```bash
kubectl cnpg psql <cluster> -n <ns> -- -c '\l'          # confirm reachable first
kubectl exec -n <ns> <cluster>-1 -- pg_dump -Fc -U postgres <db> > <ns>-<db>.dump
```

Verify each one is restorable, not merely non-empty — a truncated custom-format
dump still has a plausible size:

```bash
pg_restore --list <ns>-<db>.dump | head
```

**Buckets** — only if step 0 showed real data. Credentials come from the
`<app>-<alias>-s3` Secret; the endpoint is the SeaweedFS S3 service:

```bash
aws --endpoint-url http://<seaweed-s3>:8333 s3 sync s3://<bucket> ./buckets/<bucket>/
```

**personal-finance-dashboard's data directory** — a plain copy; it is a
hostPath today:

```bash
cp -a /home/lestherll/projects/personal-finance-dashboard/data ./pfd-data
```

Then stop k3s and give the machine back to the VM:

```bash
sudo systemctl stop k3s
sg libvirt -c "virsh start homelab"
talosctl --talosconfig /tmp/talos/talosconfig -n 10.10.0.10 -e 10.10.0.10 services
```

## Step 2 — Point Flux at the new cluster

Merge `feat/talos-cutover-infra` to `main` **now**, not earlier. Everything on
it assumes guest-only paths and a cluster with no k3s addons.

Bootstrap Flux. `clusters/homelab/flux-system/` already exists in the repo from
the previous bootstrap; re-running against a fresh cluster reuses it:

```bash
export KUBECONFIG=/tmp/kubeconfig
export GITHUB_TOKEN=<a token with repo scope>
flux bootstrap github \
  --owner=lestherll --repository=homelab \
  --branch=main --path=clusters/homelab
```

**Create the age secret before anything under `infrastructure/` reconciles.**
The `infrastructure` Kustomization sets `decryption.secretRef: sops-age`; without
it every SOPS-encrypted secret fails to decrypt and the Kustomization sticks
NotReady with an error that reads like a manifest problem:

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

Then watch it come up. `infrastructure/seaweedfs-runtime` is a *separate*
Kustomization that `dependsOn` the first, so it stays pending until the operator
is healthy — that is by design, not a stall:

```bash
flux get kustomizations --watch
kubectl get helmreleases -A
```

Expect the Pending `kubernetes.io/kubelet-serving` CSR to be approved
automatically once `kubelet-serving-cert-approver` lands, and `kubectl top` to
start working shortly after.

## Step 3 — Restore

App repos' `Database`/`Application` instances re-create **empty** as Flux
reconciles them. Let that finish, then load the data back:

```bash
kubectl exec -i -n <ns> <cluster>-1 -- pg_restore -U postgres -d <db> --clean --if-exists < <ns>-<db>.dump
aws --endpoint-url http://<seaweed-s3>:8333 s3 sync ./buckets/<bucket>/ s3://<bucket>
```

**personal-finance-dashboard needs a code change first.** Its repo still sets
`persistence.hostPath`, which revision 3 of the `Application` RGD removed, so its
instance will not reconcile until that repo switches to `size`/`tier`. Once it
does, copy the data into the new PVC through a pod — there is no host path any
more:

```bash
kubectl cp ./pfd-data/. <ns>/<pod>:/app/data
```

Its host-side CLI does not come back. That was accepted when this was planned;
it moves into a container or becomes an endpoint on the app.

## Step 4 — Verify

```bash
kubectl get nodes,kustomizations -A
kubectl get helmreleases -A                  # all Ready
kubectl get databases,objectstorages,applications -A   # Resolved=true, no unresolvedRefs
kubectl get pvc -A                           # all Bound, correct classes
kubectl top nodes                            # proves metrics-server + the CSR chain
```

All four tailnet ingresses should serve TLS: grafana, alertmanager,
fastapi-echo, personal-finance-dashboard. Expect **~4 fresh Let's Encrypt
issuances** — recreating an exposure always burns a certificate. Prune the stale
`ts-*` devices in the tailnet admin console. If one hangs rather than errors,
read the ACME note in `AGENT.md` before touching the manifest, and do **not**
retry in a loop: five failures on one hostname in an hour trips a rate limit
that each further attempt extends.

Do **not** verify RAPL or the power dashboards. They are dark by design in a
guest (LES-97); their being empty is not a failed cutover.

## Rollback

Honest about what is and isn't recoverable.

**Before step 2** it is clean: `virsh shutdown homelab && sudo systemctl start k3s`
brings the old platform back exactly as it was. k3s is disabled, not deleted,
and its data is untouched on disk. Re-enable with `systemctl enable k3s`.

**After step 2** it is not. Bootstrapping Flux against the new cluster and
merging the branch means `main` no longer describes anything k3s can run. Going
back means reverting the merge and re-bootstrapping Flux into k3s — possible,
but it is a rebuild, not a rollback. The k3s *data* is still on disk either way;
what you lose is the quick path back.

The real protection is step 1. If those dumps are not verified, do not start
step 2.

## Afterwards

- `systemctl disable k3s` is already done; the data directories
  (`/var/lib/rancher/k3s/storage`, `/mnt/storage/k8s-volumes`) still hold the old
  volumes. Leave them until the new cluster has run for a while, then reclaim —
  that is LES-99's territory along with retiring the last k3s-shaped host state.
- Backups (LES-68) remain unbuilt. This runbook hand-carried the data once; the
  next rebuild has nothing. That is the immediate follow-up, not a later nicety.
- The watchdog (LES-98) proves the host is alive, which now says little about
  whether the VM is.

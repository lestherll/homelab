# Zero-touch app registration

How an app repo puts itself on the platform without anyone touching this repo.

Registering an app used to mean a commit here: a `GitRepository` and a
`Kustomization` pointing Flux at the app's own repo, about twenty lines, once
per app forever. Everything else about the app already lived in the app's own
repo. This closes that last gap — the app's CI creates those two objects
itself, authenticating with a token GitHub signs per run.

**Nothing in this repo changes when a new app is onboarded.** Not a manifest,
not an RBAC rule, not the tailnet policy. That is the whole design goal; if a
future change makes onboarding require an edit here, that change has broken the
feature even if everything still works.

## The identity chain

Four links, none of them a stored credential:

1. **Reaching the cluster.** The apiserver lives on `10.10.0.10`, a libvirt
   network reachable only from the host. `infrastructure/tailscale-runtime/`
   exposes it to the tailnet as `kube-apiserver-ci.<tailnet>.ts.net` via the
   operator's apiserver proxy in **noauth** mode. Noauth forwards requests
   unmodified, which is what lets the next link work at all.
2. **Joining the tailnet.** The app's workflow brings up Tailscale as `tag:ci`
   for the length of the run.
3. **Authenticating.** GitHub mints an OIDC token for audience `homelab-k8s`.
   The apiserver validates it against GitHub's public keys and maps it to a
   username of `gha:` + the `sub` claim, and a group of `gha:` +
   `repository_owner` — so every repo under this account is `gha:lestherll`.
   Configured in `terraform/modules/talos-cluster/talos.tf`.
4. **Authorization, in two halves.** A `RoleBinding` in `flux-system` grants
   the group access to the two Flux kinds and nothing else. A
   `ValidatingAdmissionPolicy` then requires the object's name to equal the
   repository in the caller's own `sub` claim. Both in
   `infrastructure/app-registrar/`.

The split in step 4 is the important part. RBAC answers "may this identity
manage Flux pointer objects?" — one rule, shared by every repo, which is what
makes onboarding free. It cannot answer "may this identity manage *this*
object?", because RBAC cannot compare a request's identity to the object it
names. The admission policy does exactly that, generically, by reading the
claim GitHub signed. **It is the security boundary between app repos; the Role
is not.**

## One-time setup: the `tag:ci` trust credential

Link 2 of the chain — joining the tailnet — needs a Tailscale credential that
GitHub Actions can federate into. This is the one piece of the feature that
lives in the admin console rather than in git, because Tailscale's trust
credentials are not expressible in `policy.hujson`.

It is created **once for the whole account**, not once per app; that is what
keeps onboarding zero-touch. In **Settings → Trust credentials → New
credential → OpenID Connect**:

- **Issuer**: GitHub Actions
- **Subject**: `repo:lestherll@37829703/*`

  Same ID-based shape as the ACL credential in `tailscale-acl/README.md` — see
  there for why the `@<id>` suffixes are not optional. The wildcard is what
  makes this credential cover every current *and future* app repo. If Tailscale
  rejects a wildcard in that position, fall back to one credential per app
  repo with `repo:lestherll@37829703/<repo>@<repo-id>:*` — onboarding then
  costs a console click per app, which is a real (if small) regression against
  this document's goal and is worth recording here if it happens.
- **Scopes**: `auth_keys` (write), and nothing else. This is the scope
  `tailscale/github-action` needs to mint the ephemeral node key; the
  credential must not be able to read devices or touch the policy file.
- **Tags**: `tag:ci`. A credential with tags may only mint keys carrying those
  tags, so this is a second, independent bound on what a compromised app-repo
  workflow can become on the tailnet — it cannot join as `tag:k8s` and start
  claiming services.

Copy the generated **Client ID** and **Audience** into each app repo's Actions
secrets as `TS_OAUTH_CLIENT_ID` and `TS_AUDIENCE`, along with
`HOMELAB_APISERVER` (`kube-apiserver-ci.<tailnet>.ts.net`).

None of the three is really secret — Tailscale's docs say as much about the
first two, and the third is a hostname that only resolves for a device already
on the tailnet. They are Actions secrets to keep tailnet-identifying strings
out of the app repos, which are public.

Note these are the *only* three, and that none of them is a cluster
credential: link 3 mints one per run.

## What an app repo adds

One workflow. Object names must equal the repository name — that is what the
admission policy enforces.

The live copies are `.github/workflows/register.yml` in `fastapi-echo` and
`personal-finance-dashboard`; copy either verbatim into a new app repo — it
refers to itself only through `github.*` context, so nothing in it is
per-app. Abridged:

```yaml
name: Register with the platform
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      action: {type: choice, options: [register, teardown], default: register}

permissions:
  contents: read
  id-token: write        # required to mint OIDC tokens; without it, both
                         # Tailscale and the cluster reject the run

jobs:
  register:
    runs-on: ubuntu-latest
    steps:
      - uses: tailscale/github-action@<sha>   # v4.1.3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          audience: ${{ secrets.TS_AUDIENCE }}
          tags: tag:ci

      - name: Mint a cluster token
        id: k8s
        run: |
          token=$(curl -sS \
            -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=homelab-k8s" | jq -r .value)
          echo "::add-mask::$token"
          echo "token=$token" >> "$GITHUB_OUTPUT"

      - name: Register
        run: |
          kubectl --server="https://${{ secrets.HOMELAB_APISERVER }}" \
                  --token="$TOKEN" \
                  apply --server-side --force-conflicts -f - <<'YAML'
          apiVersion: source.toolkit.fluxcd.io/v1
          kind: GitRepository
          metadata:
            name: ${{ github.event.repository.name }}
            namespace: flux-system
          spec:
            interval: 5m
            url: ${{ github.server_url }}/${{ github.repository }}
            ref:
              branch: main
          ---
          apiVersion: kustomize.toolkit.fluxcd.io/v1
          kind: Kustomization
          metadata:
            name: ${{ github.event.repository.name }}
            namespace: flux-system
          spec:
            interval: 5m
            path: ./deploy
            prune: true
            sourceRef:
              kind: GitRepository
              name: ${{ github.event.repository.name }}
          YAML
```

`--server-side` is deliberate: server-side apply needs only `patch`, which
keeps the Role's verb list honest about what CI actually does.

`--force-conflicts` is deliberate too, and is about **adoption**, not about
overriding anyone. An object these workflows inherit from a hand-written
manifest still carries `kustomize-controller` in its `managedFields`, and
server-side apply refuses to change a field another manager owns. Verified on
the live cluster: an identical apply co-owns the fields silently, but changing
so much as `spec.interval` fails with `conflict with "kustomize-controller"`.
Without the flag the migration below appears to work and then silently stops
tracking the workflow's edits. Once the object is CI-owned the flag is inert.

Teardown is the same workflow under `workflow_dispatch` running `kubectl
delete` on the two objects. The admission policy scopes `DELETE` the same way
it scopes `CREATE`, so a repo can only delete its own. It deletes the
`Kustomization` first and waits: that object has `prune: true`, so its removal
is what tears the app's workloads down, and dropping the `GitRepository` first
would leave Flux unable to resolve the source mid-prune.

## Migrating an app that was registered by hand

`fastapi-echo` and `personal-finance-dashboard` predate this feature — their
pointer objects were files in `infrastructure/`. Moving one across is not just
deleting the file, because the `Kustomization` has `prune: true`: Flux
garbage-collecting it deletes every workload it applied. **A live app goes down
if this is done in the wrong order.**

The sequence, which is also the rebuild procedure if it ever needs repeating:

1. **Annotate, in its own commit.** Add
   `kustomize.toolkit.fluxcd.io/prune: disabled` to both objects and merge.
   Flux reads that annotation off the *live* object when it garbage-collects,
   so it has to be applied before the file goes away — annotating and deleting
   in one commit does nothing at all, since Flux never sees the annotation and
   prunes on the same reconcile.
2. **Confirm it landed** — `kubectl get kustomization <app> -n flux-system
   -o jsonpath='{.metadata.annotations}'`. Flux tracks `main`; an unmerged
   branch has changed nothing.
3. **Delete the files** in a second commit. The objects drop out of Flux's
   inventory and stay running, now managed by nobody.
4. **Run the app repo's registration workflow.** CI adopts both objects.
5. **Strip the annotation** — `kubectl annotate {gitrepository,kustomization}/<app>
   -n flux-system kustomize.toolkit.fluxcd.io/prune-`. It described a hand-off
   that has finished; leaving it makes the object look like it is still opted
   out of something.

Steps 3 and 4 are the only window where the objects have no manager, and
nothing prunes them during it — an unmanaged Flux object keeps reconciling
exactly as before. The order is about avoiding deletion, not downtime.

## Test matrix

The admission policy is the isolation boundary, so it gets tested as one rather
than by confirming a single happy path. Impersonation reproduces the exact
identity the apiserver builds from a real token, without needing a real token:

```bash
sub() { echo "gha:repo:lestherll@37829703/$1@$2:ref:refs/heads/main"; }
try() {  # try <identity-repo> <object-name>
  kubectl --as="$(sub "$1" 999)" --as-group=gha:lestherll \
    -n flux-system create -f - --dry-run=server <<YAML
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: {name: $2, namespace: flux-system}
spec: {interval: 5m, url: https://example.com/x, ref: {branch: main}}
YAML
}
```

| Case | Expected |
| --- | --- |
| `try fastapi-echo fastapi-echo` | allowed |
| `try fastapi-echo-evil fastapi-echo` | **denied** — prefix must not match |
| `try fastapi-echo fastapi-echo-evil` | **denied** — nor the reverse |
| identity without `gha:lestherll` group | denied by RBAC, before admission |
| same identity, namespace other than `flux-system` | denied by RBAC |
| `DELETE` of another repo's object | **denied** |
| admin client cert, any object | allowed — policy does not govern humans |

The middle two are the ones that matter. They are why the policy compares with
`==` rather than `startsWith` or `contains`: a substring test passes both.

## Accepted limitations

- **A rebuild from git will not recreate these objects.** They are the one
  object class in the cluster that git does not describe — deliberately, since
  describing them here is the thing being removed. After a rebuild, each app's
  registration workflow must be re-run. This is a real dent in
  reconstructibility and is accepted, not overlooked.
- **The boundary is between app repos, not between an app repo and the
  cluster.** A `Kustomization` is reconciled by Flux, which runs as
  cluster-admin, so anything CI can point Flux at can land anywhere. Binding to
  `repository_owner` means every repo under this account is trusted with the
  cluster. Isolation stops repo A clobbering repo B; it does not sandbox either
  from the platform.
- **No reaction to a repo being deleted or archived.** Teardown is a workflow
  someone runs. A repo that disappears without it leaves its objects behind,
  and Flux keeps trying to reconcile a source that no longer exists. Policy,
  not automation.
- **Human `kubectl` cannot use this path.** Noauth mode does not forward client
  certificates. Human access stays the direct route from the host; see LES-104.

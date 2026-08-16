#!/usr/bin/env bash
# Generate the Talos PKI once, out of band, and store it SOPS-encrypted.
#
# WHY THIS EXISTS, rather than `resource "talos_machine_secrets"`:
#
# Terraform has no state encryption at any version — state confidentiality is a
# property of the backend, not of the CLI. If Terraform generated the Talos PKI,
# terraform.tfstate would become the only copy of the cluster's root CA keys,
# i.e. a second root secret sitting next to the age key. D12 says there is one
# key.
#
# Generating here instead makes the age-encrypted file authoritative and leaves
# anything in state a derived copy: losing or leaking tfstate is then a rotation
# job, not a loss of the cluster.
#
# Run once per cluster. Re-running would mint a NEW PKI, which does not "fix" a
# cluster — it orphans it, because the running nodes still trust the old CA.
#
# Usage: terraform/scripts/gen-talos-secrets.sh <cluster-name>

set -euo pipefail

CLUSTER="${1:?usage: $0 <cluster-name>}"
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUT="${REPO_ROOT}/terraform/clusters/${CLUSTER}/machine-secrets.sops.json"
# talosctl's native format, kept alongside the provider-shaped one. See below.
OUT_TALOSCTL="${REPO_ROOT}/terraform/clusters/${CLUSTER}/talos-secrets.sops.yaml"

if [[ -e "${OUT}" || -e "${OUT_TALOSCTL}" ]]; then
  echo "refusing to overwrite ${OUT}" >&2
  echo "a Talos PKI already exists for '${CLUSTER}'. Regenerating it would orphan" >&2
  echo "any running cluster that trusts the current CA. Delete it deliberately if" >&2
  echo "that is really what you want." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

talosctl gen secrets -o "${TMP}/secrets.yaml"

# talosctl's on-disk format and the Terraform provider's machine_secrets schema
# disagree on key names. Translating here means the encrypted file already holds
# the provider's shape, so a mismatch shows up at plan time rather than halfway
# through an apply. Verified against talosctl v1.13.8 and
# siderolabs/talos 0.11.0, 2026-08-16:
#
#   talosctl                            provider
#   certs.<x>.crt                    →  certs.<x>.cert
#   certs.k8saggregator              →  certs.k8s_aggregator
#   certs.k8sserviceaccount          →  certs.k8s_serviceaccount
#   secrets.bootstraptoken           →  secrets.bootstrap_token
#   secrets.secretboxencryptionsecret → secrets.secretbox_encryption_secret
#
# aescbc_encryption_secret is intentionally absent: it is optional in the
# provider schema and modern Talos uses secretbox instead.
python3 - "${TMP}/secrets.yaml" "${TMP}/machine-secrets.json" <<'PY'
import json, sys, yaml

src, dst = sys.argv[1], sys.argv[2]
s = yaml.safe_load(open(src))

def pair(node):
    return {"cert": node["crt"], "key": node["key"]}

out = {
    "cluster": {
        "id":     s["cluster"]["id"],
        "secret": s["cluster"]["secret"],
    },
    "secrets": {
        "bootstrap_token":            s["secrets"]["bootstraptoken"],
        "secretbox_encryption_secret": s["secrets"]["secretboxencryptionsecret"],
    },
    "trustdinfo": {
        "token": s["trustdinfo"]["token"],
    },
    "certs": {
        "etcd":               pair(s["certs"]["etcd"]),
        "k8s":                pair(s["certs"]["k8s"]),
        "k8s_aggregator":     pair(s["certs"]["k8saggregator"]),
        "k8s_serviceaccount": {"key": s["certs"]["k8sserviceaccount"]["key"]},
        "os":                 pair(s["certs"]["os"]),
    },
}
json.dump(out, open(dst, "w"), indent=2)
PY

mkdir -p "$(dirname "${OUT}")"

# Keep talosctl's OWN format too, not just the provider's.
#
# These are the same keys in two spellings, but talosctl cannot read the
# provider's shape, and talosctl is what produces a talosconfig:
#
#   talosctl gen config <cluster> <endpoint> --with-secrets secrets.yaml
#
# Without a talosconfig there is no `talosctl kubeconfig`, no `talosctl
# dmesg`, and no way to reach a node that has no shell and no SSH. Terraform
# cannot fill that gap — its client configuration is deliberately ephemeral, so
# it can never be written to a file. Storing only the provider's shape would
# mean holding the cluster's PKI and still being locked out of the machine.
sops --encrypt --filename-override "${OUT_TALOSCTL}" \
  --input-type yaml --output-type yaml \
  "${TMP}/secrets.yaml" > "${OUT_TALOSCTL}"
echo "wrote ${OUT_TALOSCTL}"

# --filename-override, because sops picks its creation rule from the INPUT
# filename. The plaintext is written to a tempdir (so an interrupted run cannot
# strand cleartext key material inside the repo), and a tempdir path matches no
# rule in .sops.yaml — sops would fail with "no matching creation rules found".
# This tells it to resolve config as though the input were the destination.
sops --encrypt --filename-override "${OUT}" "${TMP}/machine-secrets.json" > "${OUT}"

echo "wrote ${OUT}"
echo
echo "Feed it to Terraform without it touching disk unencrypted:"
echo "  export TF_VAR_machine_secrets=\"\$(sops --decrypt --output-type json ${OUT})\""
echo "  terraform apply"

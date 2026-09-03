# Homelab Platform — Concept

A single-user Kubernetes developer platform: declare an app, a database, or
object storage, and get it provisioned, deployed, observed, and backed up
without hand-wiring any of it.

## What it is

An Ubuntu host, bootstrapped with Ansible into a hypervisor, runs a single
Talos VM under Terraform. Kubernetes on that VM is GitOps-managed by Flux and
reachable over Tailscale. On top of it, a self-service typed API (`kro`)
exposes three product types — `Database`, `ObjectStorage`, `Application` —
so that provisioning one is a short YAML file in an app's own repo, not a
hand-built instance in this one.

## Why it exists

Two reasons, held in tension: it's the scaffolding personal projects
otherwise need built by hand every time (a place to run code, a database, a
way to know it's alive), and it's the platform-engineering layer — cluster
operations, GitOps, self-service APIs, observability design — that isn't
touched day to day elsewhere. Where the two pull apart, the learning wins:
if the "correct" answer is a managed service and the interesting answer is
running it yourself, this repo runs it yourself.

## Ground rules

- **Single operator, single tenant.** No multi-tenancy, quotas, or
  chargeback. Self-service still matters — the abstraction gets built even
  though there's one person behind it.
- **Git is the record of state.** Most change is a commit; anything
  triggered directly (a break-glass fix, a session-lifecycle action) has to
  converge back into git within a bounded window.
- **Rebuildability over uptime.** Being able to restore the whole platform
  from git plus one key matters more than never going down.
- **Observable by default.** A capability isn't done until it emits metrics
  and has an alert; nothing ships silent.
- **Boring where it doesn't teach.** Novelty is spent on the platform layer,
  not the OS or the language underneath it.

## Where the detail lives

This file stays a short pitch on purpose. The reasoning behind specific
decisions, tradeoffs, and how the system got to its current shape lives
in `AGENT.md` (current state and operational facts), `docs/README.md` (the
index into the rest of `docs/`), and `docs/journal/` (dated engineering
findings). Prior revisions of this document, including a full numbered
decision log, are in git history.

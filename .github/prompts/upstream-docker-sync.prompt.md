---
description: "Compare this Hermes WebUI fork's Docker surfaces against upstream/master and produce a minimal sync plan before rebasing, publishing images, or changing compose behavior."
name: "Upstream Docker Sync"
argument-hint: "Optional focus: compose ports, GHCR images, env template, permission handling, or Docker docs drift"
agent: "Hermes Docker Fork"
---
Compare this fork's Docker surfaces against `upstream/master` and return a plan only.

Scope:
- `docker-compose.yml`
- `docker-compose.two-container.yml`
- `docker-compose.three-container.yml`
- `.env.docker.example`
- `docs/docker.md`
- `README.md` only if the Docker quick-start or operator-facing Docker guidance is implicated

Instructions:
- Confirm `git remote -v` first and use `upstream/master` as the comparison baseline.
- Summarize drift in these buckets:
  1. port mappings and container topology
  2. image source policy and GHCR references
  3. env-template and permission-handling differences
  4. Docker docs drift
- For each difference, classify it as `keep`, `drop`, or `investigate`.
- Prefer minimal deltas that preserve upstream compatibility while staying workable on this fork.
- If live local port conflicts exist, describe them as host-port mapping concerns, not container-port changes.
- Do not edit files unless the user explicitly asks for implementation after the plan.

Output format:
1. Current baseline
2. Drift summary
3. Recommended sync order
4. Exact files to update
5. Validation commands
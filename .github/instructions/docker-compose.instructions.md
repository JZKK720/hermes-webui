---
description: "Use when editing Hermes WebUI Docker Compose files, .env.docker.example, or Docker docs. Covers port boundaries, image-source policy, permission-handling rules, and required doc sync."
name: "Docker Compose Surfaces"
applyTo:
  - "docker-compose*.yml"
  - ".env.docker.example"
  - "docs/docker.md"
---
# Docker Compose Change Rules

- Read [docs/docker.md](../../docs/docker.md) before changing Docker behavior.
- Preserve the container-port split used by this repo:
  - `8642` is the Hermes gateway port.
  - `8787` is the Hermes WebUI port.
  - `9119` is the Hermes dashboard port in the three-container setup.
- If a local machine already uses one of those host ports, change the host-side published port first. Do not change the container-side port or the app's internal env var unless the application itself must listen on a different port.
- Keep single-container behavior separate from two- and three-container behavior.
- In multi-container compose files, prefer upstream image references unless the user explicitly asks for a fork image workflow:
  - WebUI: `ghcr.io/nesquena/hermes-webui:latest`
  - Agent and dashboard: `nousresearch/hermes-agent:latest`
- Do not copy WebUI `HERMES_HOME_MODE=0640` guidance into the agent service. In the agent image, `HERMES_HOME_MODE` applies to the home directory and must retain execute bits.
- Preserve named-volume defaults unless the task is specifically about bind-mount migration or host-directory sharing.
- Before proposing fork-sync or image-source changes, check remotes and compare with `upstream/master` rather than assuming this fork should diverge.
- If Docker behavior changes, update the smallest relevant doc surface in the same task:
  - [docs/docker.md](../../docs/docker.md)
  - [.env.docker.example](../../.env.docker.example)
  - [README.md](../../README.md) only when quick-start or operator-facing guidance changes
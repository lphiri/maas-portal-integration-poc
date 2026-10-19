# Repository Component Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate Keycloak into a reusable component and make the MaaS portal deploy a peer that depends on it.

**Architecture:** Keycloak becomes `components/keycloak`. The portal deployment becomes `deploy/maas-portal` and references the Keycloak component. Documentation, helper scripts, and debug assets move into dedicated top-level directories.

**Tech Stack:** Kubernetes YAML, Kustomize, Bash, OpenShift CLI.

**Spec:** This plan implements the repository layout agreed in chat.

## Global Constraints

- Keep the current root command `oc kustomize .` working.
- Keep local ignored files out of Git.
- Keep changes focused on repository structure and path updates.

## Review Focus

- Root Kustomize still renders the full stack.
- Portal Kustomize still renders without Keycloak when needed.
- Keycloak Kustomize still renders independently.
- Helper scripts still read the moved `parameters.env`.
- Debug bundle still reads the moved `parameters.env`.

### Task 1: Move repository assets

**Files:**
- Move: `keycloak/**` to `components/keycloak/**`
- Move: portal manifests and Kustomize files to `deploy/maas-portal/**`
- Move: notes to `docs/**`
- Move: helper scripts to `scripts/**`
- Move: `debug-httpbin/**` to `debug/httpbin/**`

**Interfaces:**
- Consumes: current repository files.
- Produces: the new component, deploy, docs, scripts, and debug directories.

- [x] Move Keycloak into `components/keycloak`.
- [x] Move the portal bundle into `deploy/maas-portal`.
- [x] Move notes, scripts, and debug assets.

### Task 2: Update paths and entry points

**Files:**
- Modify: root `kustomization.yaml`
- Modify: `deploy/maas-portal/kustomization.yaml`
- Modify: helper scripts under `scripts/`
- Modify: `debug/httpbin/kustomization.yaml`
- Modify: root `README.md`

**Interfaces:**
- Consumes: the new directory layout.
- Produces: working root, portal, Keycloak, and debug build commands.

- [x] Make the root Kustomize compose the portal deploy.
- [x] Make the portal deploy reference the Keycloak component.
- [x] Update helper scripts to read `deploy/maas-portal/parameters.env`.
- [x] Update the debug bundle to read the moved parameters file.
- [x] Update the root README to describe the new layout.

### Task 3: Validate

**Files:**
- Test: root Kustomize build.
- Test: portal Kustomize build.
- Test: Keycloak Kustomize build.
- Test: debug Kustomize build.

**Interfaces:**
- Consumes: the updated Kustomize files.
- Produces: successful renders.

- [x] Run `oc kustomize .`.
- [x] Run `oc kustomize deploy/maas-portal`.
- [x] Run `oc kustomize components/keycloak`.
- [x] Run the debug bundle render command.

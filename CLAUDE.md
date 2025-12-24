# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Portfolio-grade DevEdgeOps lab focused on edge constraints (ARM64, low memory, intermittent connectivity, resilience).

## Target Deployment

- Raspberry Pi (ARM64) running Raspberry Pi OS (or Ubuntu Server ARM64)
- K3s cluster (start with 1 node, expand to multi-node)

## Core Stack (phased)

**Phase 1: Foundation**
- K3s install + edge tuning
- Cluster validation checklist
- Repo scaffolding + documentation

**Phase 2: Messaging**
- Mosquitto MQTT broker (Kubernetes manifests)
- Persistence + QoS guidance

**Phase 3: Workload**
- Containerized Python service
- MQTT subscribe/publish
- /metrics endpoint (Prometheus)

**Phase 4: Observability**
- Minimal Prometheus deployment
- Targeted scraping + essential metrics

**Phase 5: Automation**
- Makefile / scripts for build + deploy + teardown
- Repeatable, documented workflows

## Constraints (non-negotiable)

- Optimize for ARM64 and low resource usage
- Design for power loss/reboot recovery
- Assume unreliable network
- Prefer simple, explainable components

## How Claude should work in this repo

- Inspect before changing anything
- Propose a plan before writing code
- Make incremental, reviewable edits (small diffs)
- Explain *why* each decision exists (tradeoffs)
- Prefer Kubernetes manifests first; introduce Helm only if justified
- Do not generate large dumps without summaries

## Validation expectations

Every phase must include:
- How to deploy
- How to verify it works
- Common failure modes + how to debug

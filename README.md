DevEdgeOps Edge K3s Lab

Portfolio-grade DevEdgeOps lab demonstrating edge computing principles with Kubernetes. This project mirrors real device-fleet edge-to-cloud platform responsibilities: resilient local compute at the edge, operation under intermittent connectivity, and observability within tight resource constraints.

Purpose

This lab focuses on real-world edge computing constraints:

ARM64 architecture optimization

Low memory environments

Intermittent connectivity

Power loss and reboot resilience

Simple, explainable platform components

Target Deployment

Hardware: Raspberry Pi (ARM64)

OS: Raspberry Pi OS Lite 64-bit (or Ubuntu Server ARM64)

Kubernetes: K3s (single-node in Phase 1, expandable to multi-node)

Phases
Phase 1: Foundation (Current)

OS preparation and hardening for edge devices

Deterministic K3s installation with edge tuning

Cluster validation checklist

Guided failure-scenario testing (reboot, power loss, network isolation, memory pressure)

Phase 2: Messaging

Mosquitto MQTT broker

Persistence and QoS configuration

Phase 3: Workload

Containerized Python service

MQTT publish/subscribe

Prometheus metrics endpoint

Phase 4: Observability

Minimal Prometheus deployment

Targeted metric scraping

Phase 5: Automation

Build, deploy, and teardown automation

Repeatable workflows

Prerequisites

Raspberry Pi 3B+ or newer (2GB+ RAM recommended)

MicroSD card (16GB+ Class 10)

Network connectivity for initial setup

SSH access to the Pi

Quick Start (Phase 1)

On a freshly installed Raspberry Pi OS Lite or Ubuntu Server:

# 1. Prepare the OS for edge workloads
sudo ./setup/os-prep-phase1.sh

# 2. Install and configure K3s
sudo ./setup/install-k3s.sh

# 3. Validate the cluster baseline
./scripts/validate-phase1.sh

# 4. Run guided failure-scenario tests
./scripts/failure-scenarios-phase1.sh


Failure scenarios are guided and non-destructive. Reboot and power-loss tests require manual action and post-recovery validation.

Documentation

Phase 1: Foundation

Troubleshooting Guide

Project Structure
edge-k3s-lab/
├── docs/          # Phase documentation
├── setup/         # OS prep and K3s installation scripts
├── k8s/           # Kubernetes manifests (organized by phase)
├── scripts/       # Validation and failure-scenario scripts
└── README.md

License

MIT
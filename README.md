# DevEdgeOps Edge K3s Lab

Portfolio-grade DevEdgeOps lab demonstrating edge computing principles with Kubernetes. This project mirrors real device-fleet edge-to-cloud platform responsibilities: resilient local compute at the edge, message routing under intermittent connectivity, and observability within tight resource constraints.

## Purpose

This lab focuses on edge computing constraints:
- ARM64 architecture optimization
- Low memory environments
- Intermittent connectivity
- Power loss resilience
- Simple, explainable components

## Target Deployment

- **Hardware**: Raspberry Pi (ARM64)
- **OS**: Raspberry Pi OS Lite 64-bit (or Ubuntu Server ARM64)
- **Kubernetes**: K3s (single-node, expandable to multi-node)

## Phases

**Phase 1: Foundation**
- K3s installation with edge tuning
- Cluster validation checklist
- Repository scaffolding

**Phase 2: Messaging**
- Mosquitto MQTT broker
- Persistence and QoS configuration

**Phase 3: Workload**
- Containerized Python service
- MQTT publish/subscribe
- Prometheus metrics endpoint

**Phase 4: Observability**
- Minimal Prometheus deployment
- Targeted metric scraping

**Phase 5: Automation**
- Build, deploy, and teardown automation
- Repeatable workflows

## Prerequisites

- Raspberry Pi 3B+ or newer (2GB+ RAM recommended)
- MicroSD card (16GB+ Class 10)
- Network connectivity for initial setup
- SSH access to the Pi

## Quick Start

_Coming in Phase 1_

## Documentation

- [Phase 1: Foundation](docs/phase1-foundation.md)
- [Troubleshooting Guide](docs/troubleshooting.md)

## Project Structure

```
edge-k3s-lab/
├── docs/          # Phase documentation
├── setup/         # Installation and configuration scripts
├── k8s/           # Kubernetes manifests (organized by phase)
├── scripts/       # Utility scripts
└── tests/         # Failure scenario tests
```

## License

MIT

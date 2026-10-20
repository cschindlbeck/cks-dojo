# CKS Dojo v1: Minimal Exam Simulator Design

## Context

[ckad-dojo](https://github.com/TiPunchLabs/ckad-dojo) is a mature CKAD exam simulator with a Python CLI, a web UI with a timer, and 20 themed exam simulations. This project (cks-dojo) adapts the idea to the CKS (Certified Kubernetes Security Specialist) exam, starting deliberately small: one exam simulation, no CLI, no web UI. The goal is to validate the content and scoring pipeline end to end before investing in tooling or additional exams.

Some ckad-dojo questions are directly relevant inspiration for CKS (NetworkPolicy default deny, SecurityContext read-only root filesystem, ServiceAccount projected tokens) and are adapted here.

## Scope

**In scope for v1:**
- One exam simulation (`cks-simulation1`) with roughly 11 questions covering all six current CKS curriculum domains.
- Pure bash tooling: idempotent setup script, scoring functions, no Python/uv dependency.
- Documentation of the target cluster (multi-node minikube with Calico CNI) as a known prerequisite.

**Out of scope for v1 (explicitly deferred, not solved here):**
- A CLI wrapper (like ckad_dojo.py) or web UI/timer.
- Additional exam simulations beyond the first.
- Support for cluster targets other than multi-node minikube with Calico.
- AppArmor questions. AppArmor is a Linux kernel feature loaded into whatever kernel actually runs the container. On Linux hosts (docker/none driver) it works via `minikube ssh`, but on Mac/Windows minikube nodes run inside Docker Desktop's VM, which typically has no AppArmor support. Skipped entirely for v1; seccomp is used instead as the primary pod/node hardening mechanism, since it works identically across all supported hosts.

## Repository Layout

```
cks-dojo/
├── README.md                       # overview, prerequisites, quick start
├── PREREQUISITES.md                # minikube multi-node + Calico setup steps
├── scripts/
│   └── lib/
│       └── common.sh                # print_success/print_fail/check_criterion helpers (ported from ckad-dojo)
├── exams/
│   └── cks-simulation1/
│       ├── exam.conf                 # metadata: name, namespaces, total points, passing %
│       ├── questions.md              # questions, ckad-dojo-style tables (points, CKS domain/weight, namespace, files)
│       ├── solutions.md              # worked solutions and explanations
│       ├── scoring-functions.sh      # score_qN() functions, one per question
│       ├── setup.sh                  # provisions namespaces/resources for this exam (idempotent)
│       ├── run-scoring.sh            # sources scoring-functions.sh, runs all score_qN, prints total
│       ├── manifests/setup/          # YAML/JSON the setup script applies
│       └── templates/                # starter YAML given to the candidate
└── exam/course/                      # candidate's working directory (gitignored, mirrors ckad-dojo's exam/course/N/)
```

No plural `exams/` sprawl yet, just the one exam folder, structured so a second exam is a copy-paste away later.

## Exam Content: cks-simulation1

Roughly 11 questions weighted to the current CKS curriculum domains:

| # | Question | CKS Domain | Weight | Points |
|---|----------|-----------|--------|--------|
| 1 | Enable audit logging on kube-apiserver with a custom audit policy | Cluster Setup | 10% | 8 |
| 2 | Restrict a namespace with a NetworkPolicy default-deny plus allow specific traffic | Cluster Hardening | 15% | 10 |
| 3 | Create an RBAC Role and RoleBinding scoped to least privilege for a ServiceAccount | Cluster Hardening | 15% | 8 |
| 4 | Disable anonymous auth and restrict insecure kubelet settings on a node | System Hardening | 15% | 8 |
| 5 | Apply a seccomp profile to a Pod, verify enforcement | System Hardening | 15% | 8 |
| 6 | Run kube-bench, remediate one failed CIS check | System Hardening | 15% | 6 |
| 7 | Harden a Pod SecurityContext (runAsNonRoot, readOnlyRootFilesystem, drop capabilities) | Minimize Microservice Vulnerabilities | 20% | 10 |
| 8 | Enforce Pod Security Admission (restricted) on a namespace | Minimize Microservice Vulnerabilities | 20% | 8 |
| 9 | Scan an image with trivy, block a CVE from being deployed | Supply Chain Security | 20% | 10 |
| 10 | Configure etcd encryption at rest for Secrets | Supply Chain Security | 20% | 8 |
| 11 | Deploy Falco, detect and verify a runtime security event | Monitoring, Logging and Runtime Security | 20% | 8 |

Total: 92 points, passing threshold ~66% (61 points), matching ckad-dojo's format.

Questions 2 and 7 are adapted from ckad-dojo's `NetworkPolicy Default Deny` and `SecurityContext - Read-Only Root Filesystem` questions respectively.

## Cluster Target

Multi-node minikube with the Calico CNI is the only supported target for v1, on a dedicated profile named `cks-dojo` so it never touches any other minikube profile a user already has running:

```
minikube start -p cks-dojo --nodes 2 --cni=calico --kubernetes-version=stable
```

Rationale: minikube uses kubeadm under the hood, so control-plane hardening (kube-apiserver static pod manifest edits via `minikube ssh`), etcd encryption at rest, audit logging, and RBAC all behave the same as on a real kubeadm-based cluster (which is also how the real CKS exam environment is built). The default minikube CNI does not enforce NetworkPolicy, so Calico is required for question 2 to be gradeable.

One-time tool installs required beyond `bash`, `kubectl`, `minikube`, and `helm` (for deploying Falco): `trivy` CLI. `kube-bench` runs as a Kubernetes Job using the official `aquasec/kube-bench` image, no local binary needed.

`PREREQUISITES.md` documents these steps and the AppArmor limitation described above. Other cluster targets (kind, cloud-managed clusters, bare kubeadm) are a known limitation, not solved for in v1.

## Setup and Scoring Mechanics

- `setup.sh`: idempotent, creates namespaces and seed resources via `kubectl apply`, safe to rerun. Reads namespace list from `exam.conf`, following the ckad-dojo pattern.
- `scoring-functions.sh`: one `score_qN()` function per question, using ported `check_criterion`/`print_success`/`print_fail` helpers from `scripts/lib/common.sh`. Each function inspects live cluster state (`kubectl get`, `kubectl exec`, `minikube ssh`, file checks under `exam/course/N/`) and prints pass/fail per criterion, then sets a global `QN_SCORE` variable.
- `run-scoring.sh`: sources `scoring-functions.sh`, calls each `score_qN` in order, sums `QN_SCORE` values, and prints a final `X / 92 (PASS/FAIL @ 66%)`.
- No timer automation. `exam.conf` documents the recommended 120-minute duration for self-timing; the candidate manages their own clock.
- Dependencies: `bash` and `kubectl` for the core flow, plus `trivy` and `helm` for the specific questions that need them.

## Validation Approach

This is exam content (bash and markdown), so validation means dogfooding rather than a unit test suite:

1. Run `setup.sh` against a fresh multi-node minikube cluster.
2. Deliberately solve each question and confirm `run-scoring.sh` awards full points.
3. Deliberately leave each question unsolved (or solve it incorrectly) and confirm `run-scoring.sh` awards zero points, to catch false positives.
4. No automated test framework is introduced for a v1 this size.

## Open Items for a Future Iteration (not part of this spec)

- A second exam simulation once this pipeline is validated.
- Whether to introduce a thin CLI wrapper once exam count grows past two or three.
- Whether to support cluster targets beyond multi-node minikube.
- Whether to add AppArmor questions as an optional, clearly-flagged bonus for Linux hosts.

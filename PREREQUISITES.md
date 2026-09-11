# Prerequisites

cks-dojo targets a dedicated, local, multi-node minikube cluster. It never touches
any other minikube profile you may already have running.

## Required tools

- `kubectl`
- `minikube` (>= 1.30)
- `helm` (for deploying Falco in question 11)
- `trivy` CLI (for question 9): `brew install trivy` or see https://aquasecurity.github.io/trivy/
- `jq` (for question 2's NetworkPolicy scoring): `brew install jq` or see https://jqlang.org/

`kube-bench` (question 6) runs as a Kubernetes Job using the official
`aquasec/kube-bench` image, no local install needed.

## Start the cluster

```bash
minikube start -p cks-dojo --nodes 2 --cni=calico --kubernetes-version=stable
```

This creates a 2-node cluster (one control-plane node named `cks-dojo`, one worker
named `cks-dojo-m02`) on its own profile, isolated from any other minikube cluster
on your machine. Allocate enough resources to Docker/your VM driver to run this
alongside anything else you have (4+ CPUs / 8+ GB RAM recommended for this profile).

Verify:

```bash
kubectl --context cks-dojo get nodes -o wide
# expect 2 Ready nodes

kubectl --context cks-dojo -n kube-system get pods | grep calico
# expect calico-node / calico-kube-controllers pods Running
```

## Known limitation: AppArmor

AppArmor is not exercised by this exam. It's a Linux kernel feature loaded into
whatever kernel actually runs the container; on Mac/Windows, minikube nodes run
inside Docker Desktop's VM, which typically has no AppArmor support. seccomp is
used instead throughout, since it behaves identically on every supported host.

## Tearing down

```bash
minikube stop -p cks-dojo    # pause
minikube delete -p cks-dojo  # remove entirely
```

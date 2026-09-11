# CKS Simulation 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first CKS exam simulation (`cks-simulation1`): 11 questions across all six CKS curriculum domains, with idempotent setup, bash-based scoring, and worked solutions, runnable against a dedicated multi-node minikube cluster.

**Architecture:** Pure bash + kubectl + minikube + helm + trivy. One `exam.conf` (metadata/namespaces), one `setup.sh` (idempotent provisioning), one `scoring-functions.sh` (one `score_qN()` per question, each setting a global `QN_SCORE`), one `run-scoring.sh` driver that sums scores and prints pass/fail. `questions.md` and `solutions.md` hold the human-facing content. No Python, no web UI, no timer automation.

**Tech Stack:** bash, kubectl, minikube (dedicated profile `cks-dojo`, 2 nodes, Calico CNI), helm, trivy CLI.

**Spec:** docs/superpowers/specs/2026-09-11-cks-dojo-minimal-design.md

## Global Constraints

- Target cluster: multi-node minikube (2 nodes) with Calico CNI, on a dedicated profile named `cks-dojo`. Never touch any other minikube profile.
- No Python/uv dependency. No CLI wrapper, no web UI, no timer automation in this v1.
- AppArmor questions are excluded. seccomp is used instead for all pod/node hardening questions, since it works identically across all supported hosts.
- 11 questions total, 92 points total, passing threshold 66% (61 points).
- Namespaces used across the exam: `net-hardening`, `rbac-lab`, `workload-security`, `psa-lab`, `supply-chain`, `monitoring`.
- All candidate work happens under `exam/course/<question-number>/`, which is gitignored.
- Every `setup.sh`/`scoring-functions.sh` change is additive: insert new content at the marked insertion points, never remove or reorder another question's block.
- Multiple questions patch the same kube-apiserver static pod manifest on the control-plane node (Q1 audit flags, Q6 `--profiling=false`, Q10 encryption config). Every edit to that manifest must be additive (append new `- --flag` lines and volume/volumeMount entries) and must never remove flags added by an earlier question.

---

## Task 1: Provision the dedicated minikube cluster

**Files:**
- Create: `PREREQUISITES.md`

**Interfaces:**
- Produces: a running minikube profile named `cks-dojo` with 2 nodes (`cks-dojo` control-plane, `cks-dojo-m02` worker) and Calico CNI, which every later task's dogfood step targets via `--context cks-dojo` / `minikube ... -p cks-dojo`.

- [ ] **Step 1: Write PREREQUISITES.md**

```markdown
# Prerequisites

cks-dojo targets a dedicated, local, multi-node minikube cluster. It never touches
any other minikube profile you may already have running.

## Required tools

- `kubectl`
- `minikube` (>= 1.30)
- `helm` (for deploying Falco in question 11)
- `trivy` CLI (for question 9): `brew install trivy` or see https://aquasecurity.github.io/trivy/

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
```

- [ ] **Step 2: Start the cluster**

Run: `minikube start -p cks-dojo --nodes 2 --cni=calico --kubernetes-version=stable`
Expected: command completes with both nodes provisioned.

- [ ] **Step 3: Verify the cluster**

Run: `kubectl --context cks-dojo get nodes -o wide`
Expected: 2 nodes, both `Ready` (`cks-dojo` and `cks-dojo-m02`).

Run: `kubectl --context cks-dojo -n kube-system get pods | grep calico`
Expected: calico pods present and `Running`.

- [ ] **Step 4: Commit**

```bash
git add PREREQUISITES.md
git commit -m "Add cks-dojo prerequisites and cluster provisioning docs"
```

---

## Task 2: Repository scaffolding

**Files:**
- Create: `.gitignore`
- Create: `scripts/lib/common.sh`
- Create: `exams/cks-simulation1/exam.conf`
- Create: `exams/cks-simulation1/setup.sh`
- Create: `exams/cks-simulation1/scoring-functions.sh`
- Create: `exams/cks-simulation1/run-scoring.sh`
- Create: `exams/cks-simulation1/questions.md`
- Create: `exams/cks-simulation1/solutions.md`

**Interfaces:**
- Produces: `check_criterion(description, "true"|"false")`, `print_success(msg)`, `print_fail(msg)`, `print_header(msg)` in `scripts/lib/common.sh`, used by every `score_qN` in later tasks.
- Produces: `$MINIKUBE_PROFILE`, `$TOTAL_QUESTIONS`, `$TOTAL_POINTS`, `$PASSING_PERCENTAGE`, `$EXAM_NAMESPACES[@]` from `exam.conf`, sourced by `setup.sh` and `scoring-functions.sh`.
- Produces: `$KCTL` array (`kubectl --context cks-dojo`) and `$LOCAL_EXAM_DIR` (`exam/course`), defined in `scoring-functions.sh` and consumed by every `score_qN`.
- Produces: the marker comments `# === END QUESTION SEED RESOURCES ===` in `setup.sh` and `# === END SCORING FUNCTIONS ===` in `scoring-functions.sh`, which every later task edits above.

- [ ] **Step 1: Write .gitignore**

```
exam/course/
```

- [ ] **Step 2: Write scripts/lib/common.sh**

```bash
#!/bin/bash
# Shared print/scoring helpers for cks-dojo exams.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() { echo -e "\n${YELLOW}$1${NC}"; }
print_success() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
print_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

# check_criterion "description" "true"|"false"
# Prints pass/fail and returns 0 (pass) or 1 (fail), so callers can do:
#   check_criterion "..." "$cond" && ((score+=N))
check_criterion() {
	local description="$1"
	local condition="$2"

	if [ "$condition" = "true" ]; then
		print_success "$description"
		return 0
	else
		print_fail "$description"
		return 1
	fi
}
```

- [ ] **Step 3: Write exams/cks-simulation1/exam.conf**

```bash
# CKS Simulation 1 - Exam Configuration

EXAM_NAME="CKS Simulation 1"
EXAM_ID="cks-simulation1"
EXAM_VERSION="1.0"

# Recommended self-timed duration (minutes). Not automated in v1.
EXAM_DURATION=120

TOTAL_QUESTIONS=11
TOTAL_POINTS=92
PASSING_PERCENTAGE=66

MINIKUBE_PROFILE="cks-dojo"

EXAM_NAMESPACES=(
	"net-hardening"
	"rbac-lab"
	"workload-security"
	"psa-lab"
	"supply-chain"
	"monitoring"
)

EXAM_PATH_PREFIX="/opt/course"
LOCAL_PATH_PREFIX="exam/course"

QUESTIONS_FILE="questions.md"
SCORING_FUNCTIONS="scoring-functions.sh"
```

- [ ] **Step 4: Write exams/cks-simulation1/setup.sh**

```bash
#!/bin/bash
set -euo pipefail

EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EXAM_DIR/../.." && pwd)"
source "$EXAM_DIR/exam.conf"

KCTL=(kubectl --context "$MINIKUBE_PROFILE")

echo "Setting up $EXAM_NAME on minikube profile '$MINIKUBE_PROFILE'..."

for ns in "${EXAM_NAMESPACES[@]}"; do
	"${KCTL[@]}" create namespace "$ns" --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
done

mkdir -p "$REPO_ROOT/exam/course"
for i in $(seq 1 "$TOTAL_QUESTIONS"); do
	mkdir -p "$REPO_ROOT/exam/course/$i"
done

# === QUESTION SEED RESOURCES (one block per question, appended below) ===

# === END QUESTION SEED RESOURCES ===

echo "Setup complete."
```

- [ ] **Step 5: Write exams/cks-simulation1/scoring-functions.sh**

```bash
#!/bin/bash
# scoring-functions.sh - one score_qN() per question. Each sets a global
# QN_SCORE and prints per-criterion pass/fail via common.sh helpers.

EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EXAM_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$EXAM_DIR/exam.conf"

KCTL=(kubectl --context "$MINIKUBE_PROFILE")
LOCAL_EXAM_DIR="$REPO_ROOT/exam/course"

# === SCORING FUNCTIONS (one score_qN per question, appended below) ===

# === END SCORING FUNCTIONS ===
```

- [ ] **Step 6: Write exams/cks-simulation1/run-scoring.sh**

```bash
#!/bin/bash
set -o pipefail

EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$EXAM_DIR/exam.conf"
source "$EXAM_DIR/scoring-functions.sh"

TOTAL_SCORE=0
for i in $(seq 1 "$TOTAL_QUESTIONS"); do
	fn="score_q${i}"
	if declare -f "$fn" >/dev/null; then
		"$fn"
		varname="Q${i}_SCORE"
		TOTAL_SCORE=$((TOTAL_SCORE + ${!varname:-0}))
	fi
done

PASS_THRESHOLD=$(((TOTAL_POINTS * PASSING_PERCENTAGE + 99) / 100))
echo
echo "===================================="
if [ "$TOTAL_SCORE" -ge "$PASS_THRESHOLD" ]; then
	echo "TOTAL: $TOTAL_SCORE / $TOTAL_POINTS -- PASS (threshold: $PASS_THRESHOLD)"
else
	echo "TOTAL: $TOTAL_SCORE / $TOTAL_POINTS -- FAIL (threshold: $PASS_THRESHOLD)"
fi
```

- [ ] **Step 7: Write exams/cks-simulation1/questions.md header**

```markdown
# CKS Simulation 1

> **Total Score**: 92 points | **Passing Score**: ~66% (61 points)
>
> Recommended duration: 120 minutes, self-timed (no automated timer in this version).
>
> Run `./setup.sh` first, solve each question under `./exam/course/N/` (mirrors the
> real exam's `/opt/course/N/` convention), then run `./run-scoring.sh`.

---
```

- [ ] **Step 8: Write exams/cks-simulation1/solutions.md header**

```markdown
# CKS Simulation 1 - Solutions

This document contains the solutions for all 11 questions in CKS Simulation 1.

---
```

- [ ] **Step 9: Make scripts executable**

Run: `chmod +x exams/cks-simulation1/setup.sh exams/cks-simulation1/run-scoring.sh scripts/lib/common.sh`

- [ ] **Step 10: Verify the skeleton runs end to end**

Run: `cd exams/cks-simulation1 && ./setup.sh`
Expected: creates the 6 namespaces on the `cks-dojo` context and the `exam/course/1`..`exam/course/11` directories, then prints "Setup complete."

Run: `./run-scoring.sh`
Expected: prints `TOTAL: 0 / 92 -- FAIL (threshold: 61)` (no `score_qN` functions defined yet, so the loop finds nothing to run).

- [ ] **Step 11: Commit**

```bash
git add .gitignore scripts/lib/common.sh exams/cks-simulation1/exam.conf exams/cks-simulation1/setup.sh exams/cks-simulation1/scoring-functions.sh exams/cks-simulation1/run-scoring.sh exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md
git commit -m "Scaffold cks-simulation1: exam.conf, setup, scoring driver"
```

---

## Task 3: Question 1 - Audit Logging

**Files:**
- Modify: `exams/cks-simulation1/questions.md` (append after the header)
- Modify: `exams/cks-simulation1/solutions.md` (append after the header)
- Modify: `exams/cks-simulation1/scoring-functions.sh` (insert above `# === END SCORING FUNCTIONS ===`)

**Interfaces:**
- Consumes: `$KCTL`, `$LOCAL_EXAM_DIR`, `$MINIKUBE_PROFILE`, `check_criterion`, `print_header` from Task 2.
- Produces: `score_q1()` setting global `Q1_SCORE`, consumed by `run-scoring.sh`.

No namespace or seed resource is needed for this question (it's cluster-wide), so `setup.sh` is not modified.

- [ ] **Step 1: Append the question to questions.md**

```markdown
## Question 1 | Audit Logging | 8 points

|                     |                                            |
| ------------------- | ------------------------------------------ |
| **Points**          | 8                                          |
| **CKS Domain**      | Cluster Setup                              |
| **CKS Weight**      | 10%                                        |
| **Namespace**       | -                                           |
| **File to create**  | `./exam/course/1/audit-policy.yaml`        |

### Task

The security team wants an audit policy that logs all requests to `secrets` and
`configmaps` at the `RequestResponse` level, and all other requests at the
`Metadata` level.

1. Write the policy to `./exam/course/1/audit-policy.yaml`.
2. Copy it onto the control-plane node at `/etc/kubernetes/audit-policy.yaml`
   (`minikube ssh -p cks-dojo -n cks-dojo`).
3. Edit the kube-apiserver static pod manifest on the control-plane node
   (`/etc/kubernetes/manifests/kube-apiserver.yaml`) to mount that file and a
   `/var/log/kubernetes/audit/` log directory, and add:
   - `--audit-policy-file=/etc/kubernetes/audit-policy.yaml`
   - `--audit-log-path=/var/log/kubernetes/audit/audit.log`
4. Confirm kube-apiserver restarts and the audit log file is being written to.

---
```

- [ ] **Step 2: Append the solution to solutions.md**

```markdown
## Question 1 | Audit Logging

**Solution:**

`./exam/course/1/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Metadata
```

Copy it to the control-plane node and wire it into kube-apiserver:

```bash
minikube cp -p cks-dojo ./exam/course/1/audit-policy.yaml cks-dojo:/etc/kubernetes/audit-policy.yaml

minikube ssh -p cks-dojo -n cks-dojo -- sudo mkdir -p /var/log/kubernetes/audit

# Inspect the current manifest before editing - exact indentation/line order
# can vary slightly by Kubernetes version.
minikube ssh -p cks-dojo -n cks-dojo -- sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml
```

Add these lines right after `- kube-apiserver` in the `command:` list, and add
matching `volumeMounts`/`volumes` entries for `/etc/kubernetes/audit-policy.yaml`
and `/var/log/kubernetes/audit`:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
```

Saving the manifest is enough - kubelet watches `/etc/kubernetes/manifests/` and
restarts the static pod automatically. Verify:

```bash
minikube ssh -p cks-dojo -n cks-dojo -- "ps aux | grep kube-apiserver"
minikube ssh -p cks-dojo -n cks-dojo -- "sudo tail -n5 /var/log/kubernetes/audit/audit.log"
```

**Explanation:** kube-apiserver is a static pod on kubeadm-based clusters
(including minikube), so editing its manifest under `/etc/kubernetes/manifests/`
and letting kubelet reconcile it is the standard way to change its flags -
there's no Deployment/Service to `kubectl edit`.

---
```

- [ ] **Step 3: Insert score_q1 into scoring-functions.sh**

Insert above `# === END SCORING FUNCTIONS ===`:

```bash
score_q1() {
	print_header "Question 1 | Audit Logging (8 points)"
	local score=0

	local local_policy="$LOCAL_EXAM_DIR/1/audit-policy.yaml"
	check_criterion "Local audit-policy.yaml exists" \
		"$([ -f "$local_policy" ] && echo true || echo false)" && ((score += 1))

	local node_policy_exists
	node_policy_exists=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
		"sudo test -f /etc/kubernetes/audit-policy.yaml && echo true || echo false" 2>/dev/null | tr -d '\r')
	check_criterion "Audit policy present on the control-plane node" \
		"${node_policy_exists:-false}" && ((score += 2))

	local apiserver_args
	apiserver_args=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
		"ps aux | grep kube-apiserver | grep -v grep" 2>/dev/null)

	local has_policy_flag="false"
	echo "$apiserver_args" | grep -q -- "--audit-policy-file=/etc/kubernetes/audit-policy.yaml" && has_policy_flag="true"
	check_criterion "kube-apiserver started with --audit-policy-file" "$has_policy_flag" && ((score += 2))

	local has_log_flag="false"
	echo "$apiserver_args" | grep -q -- "--audit-log-path=" && has_log_flag="true"
	check_criterion "kube-apiserver started with --audit-log-path" "$has_log_flag" && ((score += 1))

	local log_has_entries="false"
	local log_path
	log_path=$(echo "$apiserver_args" | grep -oE -- '--audit-log-path=[^ ]+' | cut -d= -f2)
	if [ -n "$log_path" ]; then
		local nonempty
		nonempty=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
			"sudo test -s $log_path && echo true || echo false" 2>/dev/null | tr -d '\r')
		[ "$nonempty" = "true" ] && log_has_entries="true"
	fi
	check_criterion "Audit log file has entries" "$log_has_entries" && ((score += 2))

	Q1_SCORE=$score
	echo "  Question 1 score: $score / 8"
}
```

- [ ] **Step 4: Dogfood - solved state scores full points**

Follow the solution steps above against the real `cks-dojo` cluster, then run:

```bash
cd exams/cks-simulation1 && ./run-scoring.sh
```

Expected: Question 1 section shows all 5 checks passing and `Q1_SCORE=8`.

- [ ] **Step 5: Dogfood - unsolved state scores zero**

Back up the manifest first (`minikube ssh -p cks-dojo -n cks-dojo -- sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak`), remove the two `--audit-*` flags and delete `./exam/course/1/audit-policy.yaml`, then rerun `./run-scoring.sh`.
Expected: Question 1 section shows all checks failing and `Q1_SCORE=0`.

Restore the manifest from the backup and recreate `audit-policy.yaml` so the cluster is back in the solved state for later tasks (later questions assume this manifest edit is still in place):

```bash
minikube ssh -p cks-dojo -n cks-dojo -- "sudo cp /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml"
```

Re-run the Step 4 solution steps, then confirm `./run-scoring.sh` shows `Q1_SCORE=8` again.

- [ ] **Step 6: Commit**

```bash
git add exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 1: audit logging"
```

---

## Task 4: Question 2 - NetworkPolicy Default Deny

**Files:**
- Modify: `exams/cks-simulation1/setup.sh` (insert above `# === END QUESTION SEED RESOURCES ===`)
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

**Interfaces:**
- Consumes: `$KCTL` from Task 2's `setup.sh`/`scoring-functions.sh`.
- Produces: `score_q2()` setting `Q2_SCORE`. Produces the `net-hardening` namespace's `backend`/`frontend` Deployments and `backend-svc` Service, which only this question's scoring depends on.

- [ ] **Step 1: Insert seed resources into setup.sh**

Insert above `# === END QUESTION SEED RESOURCES ===`:

```bash
# --- Question 2: net-hardening seed workloads ---
"${KCTL[@]}" -n net-hardening create deployment backend --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening expose deployment backend --port=80 --target-port=80 --name=backend-svc --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening create deployment frontend --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening rollout status deployment/backend --timeout=60s
"${KCTL[@]}" -n net-hardening rollout status deployment/frontend --timeout=60s
```

(`kubectl create deployment <name>` sets the pod template label `app=<name>` by default, so `backend` pods are labeled `app=backend` and `frontend` pods `app=frontend` with no extra steps.)

- [ ] **Step 2: Append the question to questions.md**

```markdown
## Question 2 | NetworkPolicy Default Deny | 10 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 10                                           |
| **CKS Domain**      | Cluster Hardening                            |
| **CKS Weight**      | 15%                                          |
| **Namespace**       | `net-hardening`                              |
| **Resources**       | NetworkPolicies                              |
| **File to create**  | `./exam/course/2/netpol.yaml`                |

### Task

The `net-hardening` namespace has two Deployments: `frontend` (label
`app=frontend`) and `backend` (label `app=backend`, exposed via Service
`backend-svc` on port 80).

Write NetworkPolicies to `./exam/course/2/netpol.yaml` and apply them so that:
- By default, no ingress traffic is allowed to any pod in `net-hardening`.
- Pods labeled `app=frontend` are allowed to reach pods labeled `app=backend`
  on TCP port 80.
- No other traffic is allowed to `backend`.

---
```

- [ ] **Step 3: Append the solution to solutions.md**

```markdown
## Question 2 | NetworkPolicy Default Deny

**Solution:**

`./exam/course/2/netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: net-hardening
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: net-hardening
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl --context cks-dojo apply -f ./exam/course/2/netpol.yaml
```

**Explanation:** an empty `podSelector: {}` with `policyTypes: [Ingress]` and no
`ingress` rules matches every pod in the namespace and denies all ingress by
default. The second policy then narrowly re-opens port 80 from `app=frontend`
to `app=backend` only. Calico enforces both.

---
```

- [ ] **Step 4: Insert score_q2 into scoring-functions.sh**

```bash
score_q2() {
	print_header "Question 2 | NetworkPolicy Default Deny (10 points)"
	local score=0
	local ns="net-hardening"

	local netpol_count
	netpol_count=$("${KCTL[@]}" -n "$ns" get networkpolicy -o name 2>/dev/null | wc -l | tr -d ' ')
	check_criterion "At least one NetworkPolicy exists in $ns" \
		"$([ "$netpol_count" -ge 1 ] && echo true || echo false)" && ((score += 2))

	local has_default_deny="false"
	"${KCTL[@]}" -n "$ns" get networkpolicy -o json 2>/dev/null | grep -q '"podSelector":{}' && has_default_deny="true"
	check_criterion "A default-deny-all NetworkPolicy is present" "$has_default_deny" && ((score += 2))

	local allowed="false"
	if "${KCTL[@]}" -n "$ns" run netpol-test-allowed --rm -i --restart=Never --image=busybox:1.36 \
		--overrides='{"apiVersion":"v1","metadata":{"labels":{"app":"frontend"}},"spec":{"containers":[{"name":"netpol-test-allowed","image":"busybox:1.36","command":["wget","-q","-T","5","-O-","http://backend-svc"]}]}}' \
		2>/dev/null; then
		allowed="true"
	fi
	check_criterion "frontend pods can reach backend-svc:80" "$allowed" && ((score += 3))

	local blocked="true"
	if "${KCTL[@]}" -n "$ns" run netpol-test-blocked --rm -i --restart=Never --image=busybox:1.36 \
		--overrides='{"apiVersion":"v1","metadata":{"labels":{"app":"other"}},"spec":{"containers":[{"name":"netpol-test-blocked","image":"busybox:1.36","command":["wget","-q","-T","5","-O-","http://backend-svc"]}]}}' \
		2>/dev/null; then
		blocked="false"
	fi
	check_criterion "pods without app=frontend cannot reach backend-svc:80" "$blocked" && ((score += 3))

	Q2_SCORE=$score
	echo "  Question 2 score: $score / 10"
}
```

- [ ] **Step 5: Dogfood - solved state scores full points**

Run `./setup.sh` (idempotent, safe to rerun), apply the solution's `netpol.yaml`, then `./run-scoring.sh`.
Expected: Question 2 shows all 4 checks passing and `Q2_SCORE=10`.

- [ ] **Step 6: Dogfood - unsolved state scores zero**

Delete both NetworkPolicies (`kubectl --context cks-dojo -n net-hardening delete networkpolicy default-deny allow-frontend-to-backend`), rerun `./run-scoring.sh`.
Expected: `Q2_SCORE=0` (both connectivity tests should now succeed since nothing blocks ingress, which is exactly why `blocked="true"` is the initial default flipped to `false` only on unexpected success - confirm the "unrelated pod" check correctly fails/prints `[FAIL]` in this unsolved state).

Reapply the solution's `netpol.yaml` so the cluster is back in the solved state.

- [ ] **Step 7: Commit**

```bash
git add exams/cks-simulation1/setup.sh exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 2: NetworkPolicy default deny"
```

---

## Task 5: Question 3 - RBAC Least Privilege

**Files:**
- Modify: `exams/cks-simulation1/setup.sh`
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

**Interfaces:**
- Produces: `score_q3()` setting `Q3_SCORE`. Produces `rbac-lab` namespace's `viewer-bot` ServiceAccount, `app-config` ConfigMap and `sample-app` Deployment, used only by this question.

- [ ] **Step 1: Insert seed resources into setup.sh**

```bash
# --- Question 3: rbac-lab seed resources ---
"${KCTL[@]}" -n rbac-lab create serviceaccount viewer-bot --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n rbac-lab create configmap app-config --from-literal=env=staging --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n rbac-lab create deployment sample-app --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
```

- [ ] **Step 2: Append the question to questions.md**

```markdown
## Question 3 | RBAC Least Privilege | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | Cluster Hardening                            |
| **CKS Weight**      | 15%                                          |
| **Namespace**       | `rbac-lab`                                   |
| **Resources**       | Role, RoleBinding                            |
| **File to create**  | `./exam/course/3/rbac.yaml`                  |

### Task

ServiceAccount `viewer-bot` exists in namespace `rbac-lab`. Create a Role and
RoleBinding, saved to `./exam/course/3/rbac.yaml`, so that `viewer-bot` can
`get`, `list`, and `watch` **pods** and **configmaps** in `rbac-lab`, and
nothing else - it must not be able to create pods, or read secrets.

---
```

- [ ] **Step 3: Append the solution to solutions.md**

```markdown
## Question 3 | RBAC Least Privilege

**Solution:**

`./exam/course/3/rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: viewer-role
  namespace: rbac-lab
rules:
  - apiGroups: [""]
    resources: ["pods", "configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-binding
  namespace: rbac-lab
subjects:
  - kind: ServiceAccount
    name: viewer-bot
    namespace: rbac-lab
roleRef:
  kind: Role
  name: viewer-role
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl --context cks-dojo apply -f ./exam/course/3/rbac.yaml
```

Verify:

```bash
kubectl --context cks-dojo auth can-i get pods -n rbac-lab --as=system:serviceaccount:rbac-lab:viewer-bot        # yes
kubectl --context cks-dojo auth can-i create pods -n rbac-lab --as=system:serviceaccount:rbac-lab:viewer-bot     # no
kubectl --context cks-dojo auth can-i get secrets -n rbac-lab --as=system:serviceaccount:rbac-lab:viewer-bot     # no
```

**Explanation:** least privilege means listing only the exact resources and
verbs needed - `pods`/`configmaps` with read-only verbs - rather than a
built-in `view` ClusterRole, which would also grant access to secrets-adjacent
and other-namespace resources.

---
```

- [ ] **Step 4: Insert score_q3 into scoring-functions.sh**

```bash
score_q3() {
	print_header "Question 3 | RBAC Least Privilege (8 points)"
	local score=0
	local ns="rbac-lab"
	local sa="system:serviceaccount:${ns}:viewer-bot"

	local role_exists="false"
	"${KCTL[@]}" -n "$ns" get role -o name 2>/dev/null | grep -q . && role_exists="true"
	check_criterion "A Role exists in $ns" "$role_exists" && ((score += 1))

	local binding_exists="false"
	"${KCTL[@]}" -n "$ns" get rolebinding -o name 2>/dev/null | grep -q . && binding_exists="true"
	check_criterion "A RoleBinding exists in $ns" "$binding_exists" && ((score += 1))

	local can_get_pods="false"
	[ "$("${KCTL[@]}" auth can-i get pods -n "$ns" --as="$sa" 2>/dev/null)" = "yes" ] && can_get_pods="true"
	check_criterion "viewer-bot can get pods" "$can_get_pods" && ((score += 2))

	local can_get_cm="false"
	[ "$("${KCTL[@]}" auth can-i get configmaps -n "$ns" --as="$sa" 2>/dev/null)" = "yes" ] && can_get_cm="true"
	check_criterion "viewer-bot can get configmaps" "$can_get_cm" && ((score += 2))

	local cannot_create_pods="false"
	[ "$("${KCTL[@]}" auth can-i create pods -n "$ns" --as="$sa" 2>/dev/null)" = "no" ] && cannot_create_pods="true"
	check_criterion "viewer-bot cannot create pods (least privilege)" "$cannot_create_pods" && ((score += 1))

	local cannot_get_secrets="false"
	[ "$("${KCTL[@]}" auth can-i get secrets -n "$ns" --as="$sa" 2>/dev/null)" = "no" ] && cannot_get_secrets="true"
	check_criterion "viewer-bot cannot get secrets (least privilege)" "$cannot_get_secrets" && ((score += 1))

	Q3_SCORE=$score
	echo "  Question 3 score: $score / 8"
}
```

- [ ] **Step 5: Dogfood - solved and unsolved states**

Run `./setup.sh`, apply the solution's `rbac.yaml`, run `./run-scoring.sh`, confirm `Q3_SCORE=8`.
Then `kubectl --context cks-dojo -n rbac-lab delete role viewer-role rolebinding viewer-binding`, rerun `./run-scoring.sh`, confirm `Q3_SCORE=0`.
Reapply the solution's `rbac.yaml` to leave the cluster solved.

- [ ] **Step 6: Commit**

```bash
git add exams/cks-simulation1/setup.sh exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 3: RBAC least privilege"
```

---

## Task 6: Question 4 - Kubelet Hardening

**Files:**
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: this question targets the worker node's kubelet directly, no seed cluster resources needed.

- [ ] **Step 1: Append the question to questions.md**

```markdown
## Question 4 | Kubelet Hardening | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | System Hardening                             |
| **CKS Weight**      | 15%                                          |
| **Namespace**       | -                                             |
| **File to create**  | `./exam/course/4/kubelet-config.yaml`        |

### Task

On the worker node `cks-dojo-m02` (`minikube ssh -p cks-dojo -n cks-dojo-m02`),
edit `/var/lib/kubelet/config.yaml` so that:
- `authentication.anonymous.enabled` is `false`.
- `readOnlyPort` is `0`.

Restart kubelet for the change to take effect, then save a copy of the edited
config to `./exam/course/4/kubelet-config.yaml`.

---
```

- [ ] **Step 2: Append the solution to solutions.md**

```markdown
## Question 4 | Kubelet Hardening

**Solution:**

```bash
minikube ssh -p cks-dojo -n cks-dojo-m02 -- sudo cat /var/lib/kubelet/config.yaml
```

Edit `authentication.anonymous.enabled` to `false` and `readOnlyPort` to `0`
(both keys already exist in the kubeadm-generated config), then:

```bash
minikube ssh -p cks-dojo -n cks-dojo-m02 -- sudo systemctl restart kubelet
minikube ssh -p cks-dojo -n cks-dojo-m02 -- sudo cat /var/lib/kubelet/config.yaml > ./exam/course/4/kubelet-config.yaml
```

**Explanation:** anonymous kubelet API access and the deprecated read-only port
(10255, unauthenticated) are common CIS benchmark findings; disabling both
forces every kubelet API caller through authenticated/authorized requests on
the secure port (10250).

---
```

- [ ] **Step 3: Insert score_q4 into scoring-functions.sh**

```bash
score_q4() {
	print_header "Question 4 | Kubelet Hardening (8 points)"
	local score=0
	local node="${MINIKUBE_PROFILE}-m02"

	local local_copy="$LOCAL_EXAM_DIR/4/kubelet-config.yaml"
	check_criterion "Local copy of kubelet config saved" \
		"$([ -f "$local_copy" ] && echo true || echo false)" && ((score += 1))

	local anon_disabled="false"
	minikube ssh -p "$MINIKUBE_PROFILE" -n "$node" -- "sudo grep -A2 'anonymous:' /var/lib/kubelet/config.yaml" 2>/dev/null |
		grep -q "enabled: false" && anon_disabled="true"
	check_criterion "anonymous.enabled is false in kubelet config" "$anon_disabled" && ((score += 2))

	local readonly_disabled="false"
	minikube ssh -p "$MINIKUBE_PROFILE" -n "$node" -- "sudo grep 'readOnlyPort' /var/lib/kubelet/config.yaml" 2>/dev/null |
		grep -q ": 0" && readonly_disabled="true"
	check_criterion "readOnlyPort is 0 in kubelet config" "$readonly_disabled" && ((score += 2))

	local kubelet_active="false"
	[ "$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$node" -- "systemctl is-active kubelet" 2>/dev/null | tr -d '\r')" = "active" ] && kubelet_active="true"
	check_criterion "kubelet is still active after the change" "$kubelet_active" && ((score += 1))

	local node_ip
	node_ip=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$node" -- "hostname -i" 2>/dev/null | tr -d '\r')
	local anon_rejected="false"
	if [ -n "$node_ip" ]; then
		# curl from the control-plane node, not the host: node-to-node traffic inside
		# minikube's network is reliable regardless of host OS/driver.
		local http_code
		http_code=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
			"curl -sk -o /dev/null -w '%{http_code}' https://${node_ip}:10250/pods --max-time 5" 2>/dev/null | tr -d '\r')
		{ [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; } && anon_rejected="true"
	fi
	check_criterion "Anonymous kubelet API access is rejected" "$anon_rejected" && ((score += 2))

	Q4_SCORE=$score
	echo "  Question 4 score: $score / 8"
}
```

- [ ] **Step 4: Dogfood - solved and unsolved states**

Apply the solution against the real cluster, run `./run-scoring.sh`, confirm `Q4_SCORE=8`.
Then revert the two config keys, restart kubelet, delete the local copy, rerun, confirm `Q4_SCORE<=1` (the "kubelet still active" check may still legitimately pass). Reapply the solution afterward.

- [ ] **Step 5: Commit**

```bash
git add exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 4: kubelet hardening"
```

---

## Task 7: Question 5 - seccomp Enforcement

**Files:**
- Create: `exams/cks-simulation1/manifests/setup/deny-chmod.json`
- Modify: `exams/cks-simulation1/setup.sh`
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

- [ ] **Step 1: Write the seccomp profile**

`exams/cks-simulation1/manifests/setup/deny-chmod.json`:

```json
{
	"defaultAction": "SCMP_ACT_ALLOW",
	"syscalls": [
		{
			"names": ["chmod", "fchmod", "fchmodat"],
			"action": "SCMP_ACT_ERRNO"
		}
	]
}
```

- [ ] **Step 2: Insert seed resources into setup.sh**

```bash
# --- Question 5: seccomp profile installed on every node ---
SECCOMP_PROFILE="$EXAM_DIR/manifests/setup/deny-chmod.json"
for node in "$MINIKUBE_PROFILE" "${MINIKUBE_PROFILE}-m02"; do
	minikube ssh -p "$MINIKUBE_PROFILE" -n "$node" -- "sudo mkdir -p /var/lib/kubelet/seccomp/profiles"
	minikube cp -p "$MINIKUBE_PROFILE" "$SECCOMP_PROFILE" "${node}:/var/lib/kubelet/seccomp/profiles/deny-chmod.json"
done
```

- [ ] **Step 3: Append the question to questions.md**

```markdown
## Question 5 | seccomp Enforcement | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | System Hardening                             |
| **CKS Weight**      | 15%                                          |
| **Namespace**       | `workload-security`                          |
| **Resources**       | Pod `seccomp-demo`                           |
| **File to create**  | `./exam/course/5/seccomp-test.txt`           |

### Task

A custom seccomp profile that denies `chmod` is already installed on every
node at `/var/lib/kubelet/seccomp/profiles/deny-chmod.json`.

Create a Pod named `seccomp-demo` in `workload-security` (image `busybox:1.36`,
command `sleep 3600`) that uses this profile via
`securityContext.seccompProfile` (`type: Localhost`,
`localhostProfile: profiles/deny-chmod.json`).

Confirm the profile is enforced by running `chmod 777 /tmp` inside the
container and observing it fail, then save that command's output to
`./exam/course/5/seccomp-test.txt`.

---
```

- [ ] **Step 4: Append the solution to solutions.md**

```markdown
## Question 5 | seccomp Enforcement

**Solution:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-demo
  namespace: workload-security
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod.json
  containers:
    - name: seccomp-demo
      image: busybox:1.36
      command: ["sleep", "3600"]
```

```bash
kubectl --context cks-dojo apply -f - <<'EOF'
# (the manifest above)
EOF

kubectl --context cks-dojo -n workload-security exec seccomp-demo -- chmod 777 /tmp \
  > ./exam/course/5/seccomp-test.txt 2>&1
```

**Explanation:** `localhostProfile` is relative to
`/var/lib/kubelet/seccomp/`, so `profiles/deny-chmod.json` resolves to the file
installed by `setup.sh`. The profile's default action allows every syscall
except `chmod`/`fchmod`/`fchmodat`, which return `EPERM`.

---
```

- [ ] **Step 5: Insert score_q5 into scoring-functions.sh**

```bash
score_q5() {
	print_header "Question 5 | seccomp Enforcement (8 points)"
	local score=0
	local ns="workload-security"
	local pod="seccomp-demo"

	local seccomp_type
	seccomp_type=$("${KCTL[@]}" -n "$ns" get pod "$pod" -o jsonpath='{.spec.securityContext.seccompProfile.type}' 2>/dev/null)
	check_criterion "Pod uses a Localhost seccompProfile" \
		"$([ "$seccomp_type" = "Localhost" ] && echo true || echo false)" && ((score += 2))

	local profile_path
	profile_path=$("${KCTL[@]}" -n "$ns" get pod "$pod" -o jsonpath='{.spec.securityContext.seccompProfile.localhostProfile}' 2>/dev/null)
	check_criterion "localhostProfile points at deny-chmod.json" \
		"$(echo "$profile_path" | grep -q "deny-chmod.json" && echo true || echo false)" && ((score += 2))

	local pod_running="false"
	[ "$("${KCTL[@]}" -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && pod_running="true"
	check_criterion "Pod is Running" "$pod_running" && ((score += 1))

	local chmod_blocked="false"
	"${KCTL[@]}" -n "$ns" exec "$pod" -- chmod 777 /tmp 2>&1 | grep -qi "not permitted" && chmod_blocked="true"
	check_criterion "chmod is blocked inside the pod by the profile" "$chmod_blocked" && ((score += 2))

	local evidence_saved="false"
	[ -s "$LOCAL_EXAM_DIR/5/seccomp-test.txt" ] && evidence_saved="true"
	check_criterion "Evidence saved to exam/course/5/seccomp-test.txt" "$evidence_saved" && ((score += 1))

	Q5_SCORE=$score
	echo "  Question 5 score: $score / 8"
}
```

- [ ] **Step 6: Dogfood - solved and unsolved states**

Run `./setup.sh`, apply the solution pod, run `./run-scoring.sh`, confirm `Q5_SCORE=8`.
Delete the pod and the evidence file, rerun, confirm `Q5_SCORE=0`. Recreate the pod and evidence file.

- [ ] **Step 7: Commit**

```bash
git add exams/cks-simulation1/manifests/setup/deny-chmod.json exams/cks-simulation1/setup.sh exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 5: seccomp enforcement"
```

---

## Task 8: Question 6 - kube-bench Remediation

**Files:**
- Create: `exams/cks-simulation1/templates/kube-bench-job.yaml`
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: this question runs a one-off Job the candidate applies themselves and edits the same kube-apiserver manifest Q1 already touched (additively - only append `--profiling=false`, don't remove Q1's flags).

- [ ] **Step 1: Write the kube-bench Job template**

`exams/cks-simulation1/templates/kube-bench-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
spec:
  template:
    spec:
      hostPID: true
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--targets", "master"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      restartPolicy: Never
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: usr-bin
          hostPath:
            path: /usr/bin
  backoffLimit: 0
```

- [ ] **Step 2: Append the question to questions.md**

```markdown
## Question 6 | kube-bench Remediation | 6 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 6                                            |
| **CKS Domain**      | System Hardening                             |
| **CKS Weight**      | 15%                                          |
| **Namespace**       | -                                             |
| **File to create**  | `./exam/course/6/kube-bench-report.txt`      |

### Task

Run kube-bench against the control-plane node using the provided
`./templates/kube-bench-job.yaml`, save its output to
`./exam/course/6/kube-bench-report.txt`, then remediate the finding about
kube-apiserver profiling by adding `--profiling=false` to the kube-apiserver
static pod manifest (alongside the audit flags already added in Question 1 -
do not remove them).

---
```

- [ ] **Step 3: Append the solution to solutions.md**

```markdown
## Question 6 | kube-bench Remediation

**Solution:**

```bash
kubectl --context cks-dojo apply -f ./templates/kube-bench-job.yaml
kubectl --context cks-dojo wait --for=condition=complete job/kube-bench --timeout=120s
kubectl --context cks-dojo logs job/kube-bench > ./exam/course/6/kube-bench-report.txt
kubectl --context cks-dojo delete job kube-bench
```

Add `- --profiling=false` right after `- kube-apiserver` in
`/etc/kubernetes/manifests/kube-apiserver.yaml` on the control-plane node,
alongside the `--audit-*` flags from Question 1:

```bash
minikube ssh -p cks-dojo -n cks-dojo -- sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml
# edit, keeping the existing --audit-policy-file / --audit-log-path lines
```

**Explanation:** `--profiling=false` disables the pprof HTTP endpoints, a
routine CIS benchmark finding since profiling exposes internal runtime data
and adds attack surface with no operational benefit in production.

---
```

- [ ] **Step 4: Insert score_q6 into scoring-functions.sh**

```bash
score_q6() {
	print_header "Question 6 | kube-bench Remediation (6 points)"
	local score=0

	local report_saved="false"
	[ -s "$LOCAL_EXAM_DIR/6/kube-bench-report.txt" ] && report_saved="true"
	check_criterion "kube-bench report saved to exam/course/6/kube-bench-report.txt" "$report_saved" && ((score += 2))

	local apiserver_args
	apiserver_args=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
		"ps aux | grep kube-apiserver | grep -v grep" 2>/dev/null)

	local profiling_disabled="false"
	echo "$apiserver_args" | grep -q -- "--profiling=false" && profiling_disabled="true"
	check_criterion "kube-apiserver started with --profiling=false" "$profiling_disabled" && ((score += 4))

	Q6_SCORE=$score
	echo "  Question 6 score: $score / 6"
}
```

- [ ] **Step 5: Dogfood - solved and unsolved states**

Apply the solution, run `./run-scoring.sh`, confirm `Q6_SCORE=6` and that `Q1_SCORE` is unaffected (still 8).
Remove `--profiling=false` only (leave Q1's flags intact) and delete the report file, rerun, confirm `Q6_SCORE=0`. Reapply.

- [ ] **Step 6: Commit**

```bash
git add exams/cks-simulation1/templates/kube-bench-job.yaml exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 6: kube-bench remediation"
```

---

## Task 9: Question 7 - Pod SecurityContext Hardening

**Files:**
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: `workload-security` namespace already exists from Task 7 (Question 5).

- [ ] **Step 1: Append the question to questions.md**

```markdown
## Question 7 | Pod SecurityContext Hardening | 10 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 10                                           |
| **CKS Domain**      | Minimize Microservice Vulnerabilities        |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | `workload-security`                          |
| **Resources**       | Deployment `hardened-app`                    |
| **File to create**  | `./exam/course/7/hardened-app.yaml`          |

### Task

Create a Deployment named `hardened-app` in `workload-security`
(image `busybox:1.36`, command `sleep 3600`) with:
- `runAsNonRoot: true` and `runAsUser` set to a non-zero UID.
- `readOnlyRootFilesystem: true`.
- `allowPrivilegeEscalation: false`.
- `capabilities.drop: ["ALL"]`.

Save the manifest to `./exam/course/7/hardened-app.yaml`.

---
```

- [ ] **Step 2: Append the solution to solutions.md**

```markdown
## Question 7 | Pod SecurityContext Hardening

**Solution:**

`./exam/course/7/hardened-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-app
  namespace: workload-security
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hardened-app
  template:
    metadata:
      labels:
        app: hardened-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: hardened-app
          image: busybox:1.36
          command: ["sleep", "3600"]
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
```

```bash
kubectl --context cks-dojo apply -f ./exam/course/7/hardened-app.yaml
```

**Explanation:** `busybox sleep` needs no writable filesystem and no
capabilities, so the full hardened profile applies cleanly with no crash
loop, unlike images that need to write to disk or bind low ports at startup.

---
```

- [ ] **Step 3: Insert score_q7 into scoring-functions.sh**

```bash
score_q7() {
	print_header "Question 7 | Pod SecurityContext Hardening (10 points)"
	local score=0
	local ns="workload-security"
	local deploy="hardened-app"

	local run_as_non_root
	run_as_non_root=$("${KCTL[@]}" -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}' 2>/dev/null)
	check_criterion "runAsNonRoot is true" \
		"$([ "$run_as_non_root" = "true" ] && echo true || echo false)" && ((score += 2))

	local run_as_user
	run_as_user=$("${KCTL[@]}" -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.template.spec.securityContext.runAsUser}' 2>/dev/null)
	check_criterion "runAsUser is a non-zero UID" \
		"$([ -n "$run_as_user" ] && [ "$run_as_user" -ne 0 ] && echo true || echo false)" && ((score += 2))

	local readonly_fs
	readonly_fs=$("${KCTL[@]}" -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
	check_criterion "readOnlyRootFilesystem is true" \
		"$([ "$readonly_fs" = "true" ] && echo true || echo false)" && ((score += 2))

	local no_escalation
	no_escalation=$("${KCTL[@]}" -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null)
	check_criterion "allowPrivilegeEscalation is false" \
		"$([ "$no_escalation" = "false" ] && echo true || echo false)" && ((score += 2))

	local drops_all
	drops_all=$("${KCTL[@]}" -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}' 2>/dev/null)
	check_criterion "capabilities.drop includes ALL" \
		"$([ "$drops_all" = "ALL" ] && echo true || echo false)" && ((score += 1))

	local pod_running="false"
	[ "$("${KCTL[@]}" -n "$ns" get pods -l app="$deploy" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = "Running" ] && pod_running="true"
	check_criterion "Pod is Running (hardening didn't break it)" "$pod_running" && ((score += 1))

	Q7_SCORE=$score
	echo "  Question 7 score: $score / 10"
}
```

- [ ] **Step 4: Dogfood - solved and unsolved states**

Apply the solution, run `./run-scoring.sh`, confirm `Q7_SCORE=10`.
Delete the deployment, rerun, confirm `Q7_SCORE=0`. Recreate it.

- [ ] **Step 5: Commit**

```bash
git add exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 7: Pod SecurityContext hardening"
```

---

## Task 10: Question 8 - Pod Security Admission

**Files:**
- Create: `exams/cks-simulation1/templates/bad-pod.yaml`
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: `psa-lab` namespace already exists from Task 2.

- [ ] **Step 1: Write the privileged pod template**

`exams/cks-simulation1/templates/bad-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test
  namespace: psa-lab
spec:
  containers:
    - name: privileged-test
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

- [ ] **Step 2: Append the question to questions.md**

```markdown
## Question 8 | Pod Security Admission | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | Minimize Microservice Vulnerabilities        |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | `psa-lab`                                    |
| **Resources**       | Namespace label                              |
| **File to create**  | -                                             |

### Task

Label the `psa-lab` namespace to enforce the `restricted` Pod Security
Standard. Confirm `./templates/bad-pod.yaml` (a privileged Pod) is rejected
once the label is applied.

---
```

- [ ] **Step 3: Append the solution to solutions.md**

```markdown
## Question 8 | Pod Security Admission

**Solution:**

```bash
kubectl --context cks-dojo label namespace psa-lab pod-security.kubernetes.io/enforce=restricted --overwrite

kubectl --context cks-dojo apply -f ./templates/bad-pod.yaml
# expect: error validating ... violates PodSecurity "restricted:latest": ...
```

**Explanation:** Pod Security Admission is a built-in admission controller
(no extra installation) that enforces the Pod Security Standards per
namespace via labels. `restricted` forbids privileged containers, host
namespaces, and requires a hardened SecurityContext similar to Question 7's.

---
```

- [ ] **Step 4: Insert score_q8 into scoring-functions.sh**

```bash
score_q8() {
	print_header "Question 8 | Pod Security Admission (8 points)"
	local score=0
	local ns="psa-lab"

	local enforce_label
	enforce_label=$("${KCTL[@]}" get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
	check_criterion "Namespace labeled pod-security.kubernetes.io/enforce=restricted" \
		"$([ "$enforce_label" = "restricted" ] && echo true || echo false)" && ((score += 3))

	local bad_pod_rejected="false"
	"${KCTL[@]}" apply -f "$EXAM_DIR/templates/bad-pod.yaml" 2>&1 | grep -qi "violat" && bad_pod_rejected="true"
	check_criterion "A privileged pod is rejected by admission control" "$bad_pod_rejected" && ((score += 3))
	"${KCTL[@]}" -n "$ns" delete pod privileged-test --ignore-not-found >/dev/null 2>&1

	local good_pod_allowed="false"
	"${KCTL[@]}" -n "$ns" run compliant-test --image=busybox:1.36 --restart=Never \
		--overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"compliant-test","image":"busybox:1.36","command":["sleep","30"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
		>/dev/null 2>&1 && good_pod_allowed="true"
	check_criterion "A compliant pod is still allowed" "$good_pod_allowed" && ((score += 2))
	"${KCTL[@]}" -n "$ns" delete pod compliant-test --ignore-not-found >/dev/null 2>&1

	Q8_SCORE=$score
	echo "  Question 8 score: $score / 8"
}
```

- [ ] **Step 5: Dogfood - solved and unsolved states**

Apply the solution, run `./run-scoring.sh`, confirm `Q8_SCORE=8`.
Remove the namespace label, rerun, confirm `Q8_SCORE<=2` (the privileged pod would now be admitted, so that check fails too). Reapply the label.

- [ ] **Step 6: Commit**

```bash
git add exams/cks-simulation1/templates/bad-pod.yaml exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 8: Pod Security Admission"
```

---

## Task 11: Question 9 - Image Vulnerability Scanning (trivy)

**Files:**
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: `supply-chain` namespace already exists from Task 2; this question uses public images directly, no local registry needed.

- [ ] **Step 1: Append the question to questions.md**

```markdown
## Question 9 | Image Vulnerability Scanning | 10 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 10                                           |
| **CKS Domain**      | Supply Chain Security                        |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | `supply-chain`                               |
| **Resources**       | Deployment `web-supply-chain`                |
| **Files to create** | `./exam/course/9/trivy-report.json`, `./exam/course/9/deployment.yaml` |

### Task

Scan the `node:14` image for CRITICAL vulnerabilities with trivy, saving the
report to `./exam/course/9/trivy-report.json`. Based on that report, deploy a
Deployment named `web-supply-chain` in `supply-chain` using a newer, patched
tag (e.g. `node:20-alpine`) instead - never deploy `node:14`. Save the
manifest to `./exam/course/9/deployment.yaml`.

---
```

- [ ] **Step 2: Append the solution to solutions.md**

```markdown
## Question 9 | Image Vulnerability Scanning

**Solution:**

```bash
trivy image node:14 --severity CRITICAL --format json -o ./exam/course/9/trivy-report.json
```

`./exam/course/9/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-supply-chain
  namespace: supply-chain
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-supply-chain
  template:
    metadata:
      labels:
        app: web-supply-chain
    spec:
      containers:
        - name: web-supply-chain
          image: node:20-alpine
          command: ["sleep", "3600"]
```

```bash
kubectl --context cks-dojo apply -f ./exam/course/9/deployment.yaml
```

**Explanation:** `node:14` is end-of-life and carries known CRITICAL CVEs;
trivy's report is the evidence that scanning happened, and the deployed image
tag is the evidence that the finding was acted on rather than ignored.

---
```

- [ ] **Step 3: Insert score_q9 into scoring-functions.sh**

```bash
score_q9() {
	print_header "Question 9 | Image Vulnerability Scanning (10 points)"
	local score=0
	local ns="supply-chain"

	local report="$LOCAL_EXAM_DIR/9/trivy-report.json"
	local report_valid="false"
	[ -s "$report" ] && grep -q "CRITICAL" "$report" && report_valid="true"
	check_criterion "trivy report saved and shows CRITICAL findings" "$report_valid" && ((score += 4))

	local deploy_image
	deploy_image=$("${KCTL[@]}" -n "$ns" get deploy web-supply-chain -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
	local uses_vulnerable="false"
	echo "$deploy_image" | grep -qE "^node:14($|-)" && uses_vulnerable="true"
	check_criterion "Deployment does NOT use the vulnerable node:14 image" \
		"$([ -n "$deploy_image" ] && [ "$uses_vulnerable" = "false" ] && echo true || echo false)" && ((score += 3))

	local pod_running="false"
	[ "$("${KCTL[@]}" -n "$ns" get pods -l app=web-supply-chain -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = "Running" ] && pod_running="true"
	check_criterion "web-supply-chain pod is Running" "$pod_running" && ((score += 2))

	local manifest_saved="false"
	[ -s "$LOCAL_EXAM_DIR/9/deployment.yaml" ] && manifest_saved="true"
	check_criterion "Deployment manifest saved to exam/course/9/deployment.yaml" "$manifest_saved" && ((score += 1))

	Q9_SCORE=$score
	echo "  Question 9 score: $score / 10"
}
```

- [ ] **Step 4: Dogfood - solved and unsolved states**

Apply the solution, run `./run-scoring.sh`, confirm `Q9_SCORE=10`.
Delete the deployment and both files, rerun, confirm `Q9_SCORE=0`. Recreate.

- [ ] **Step 5: Commit**

```bash
git add exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 9: image vulnerability scanning"
```

---

## Task 12: Question 10 - etcd Encryption at Rest

**Files:**
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: this edits the same control-plane node and the same kube-apiserver manifest as Questions 1 and 6 (additively).

- [ ] **Step 1: Append the question to questions.md**

```markdown
## Question 10 | etcd Encryption at Rest | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | Supply Chain Security                        |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | -                                             |
| **File to create**  | `./exam/course/10/encryption-config.yaml`    |

### Task

Configure encryption at rest for Secrets:

1. Write an `EncryptionConfiguration` (aescbc provider) to
   `./exam/course/10/encryption-config.yaml`.
2. Copy it onto the control-plane node at
   `/etc/kubernetes/enc/encryption-config.yaml`.
3. Add `--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml`
   to the kube-apiserver static pod manifest (alongside the flags from
   Questions 1 and 6 - do not remove them), with a matching volume mount.
4. Create a Secret named `cks-secret` in the `default` namespace and confirm,
   by reading it directly out of etcd, that its value is stored encrypted
   (prefixed `k8s:enc:`).

---
```

- [ ] **Step 2: Append the solution to solutions.md**

```markdown
## Question 10 | etcd Encryption at Rest

**Solution:**

`./exam/course/10/encryption-config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: c2VjcmV0IGlzIHNlY3VyZSBpc24ndCBpdD8=
      - identity: {}
```

```bash
minikube ssh -p cks-dojo -n cks-dojo -- sudo mkdir -p /etc/kubernetes/enc
minikube cp -p cks-dojo ./exam/course/10/encryption-config.yaml cks-dojo:/etc/kubernetes/enc/encryption-config.yaml
```

Add `- --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml`
right after `- kube-apiserver`, and a matching `volumeMounts`/`volumes` entry
for `/etc/kubernetes/enc`, in
`/etc/kubernetes/manifests/kube-apiserver.yaml` on the control-plane node -
keep the `--audit-*` and `--profiling=false` flags from Questions 1 and 6.

```bash
kubectl --context cks-dojo create secret generic cks-secret --from-literal=password=SuperSecret123

ETCD_POD=$(kubectl --context cks-dojo -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')
kubectl --context cks-dojo -n kube-system exec "$ETCD_POD" -- sh -c \
  'ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/default/cks-secret'
# expect the value to start with k8s:enc:aescbc:v1:key1: and not contain "SuperSecret123" in plaintext
```

**Explanation:** without `--encryption-provider-config`, etcd stores Secret
values as base64-encoded plaintext (trivially reversible). The
`EncryptionConfiguration` tells kube-apiserver to encrypt Secret values with
the `aescbc` provider before writing them to etcd; the `k8s:enc:` prefix in
the raw etcd value is the evidence encryption is active.

---
```

- [ ] **Step 3: Insert score_q10 into scoring-functions.sh**

```bash
score_q10() {
	print_header "Question 10 | etcd Encryption at Rest (8 points)"
	local score=0

	local local_copy="$LOCAL_EXAM_DIR/10/encryption-config.yaml"
	check_criterion "Local copy of encryption-config.yaml saved" \
		"$([ -f "$local_copy" ] && echo true || echo false)" && ((score += 1))

	local apiserver_args
	apiserver_args=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
		"ps aux | grep kube-apiserver | grep -v grep" 2>/dev/null)

	local flag_present="false"
	echo "$apiserver_args" | grep -q -- "--encryption-provider-config=" && flag_present="true"
	check_criterion "kube-apiserver started with --encryption-provider-config" "$flag_present" && ((score += 2))

	"${KCTL[@]}" create secret generic cks-secret --from-literal=password=SuperSecret123 \
		--dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null 2>&1

	local etcd_pod
	etcd_pod=$("${KCTL[@]}" -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

	local raw_value=""
	local encrypted="false"
	if [ -n "$etcd_pod" ]; then
		raw_value=$("${KCTL[@]}" -n kube-system exec "$etcd_pod" -- sh -c \
			'ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/default/cks-secret' \
			2>/dev/null)
		echo "$raw_value" | grep -q "k8s:enc:" && encrypted="true"
	fi
	check_criterion "cks-secret is stored encrypted in etcd (k8s:enc: prefix)" "$encrypted" && ((score += 4))

	local plaintext_absent="false"
	if ! echo "$raw_value" | grep -q "SuperSecret123"; then
		plaintext_absent="true"
	fi
	check_criterion "Secret plaintext value is not visible in raw etcd output" "$plaintext_absent" && ((score += 1))

	Q10_SCORE=$score
	echo "  Question 10 score: $score / 8"
}
```

- [ ] **Step 4: Dogfood - solved and unsolved states**

Apply the solution, run `./run-scoring.sh`, confirm `Q10_SCORE=8` and `Q1_SCORE`/`Q6_SCORE` unaffected.
Remove only the `--encryption-provider-config` flag (leave the others), delete `cks-secret` from etcd's perspective isn't possible to "unencrypt" retroactively - instead create a **new** secret `cks-secret-test` while the flag is removed and confirm its raw etcd value has no `k8s:enc:` prefix, proving the check is sound. Reapply the flag afterward.

- [ ] **Step 5: Commit**

```bash
git add exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 10: etcd encryption at rest"
```

---

## Task 13: Question 11 - Falco Runtime Security

**Files:**
- Modify: `exams/cks-simulation1/questions.md`
- Modify: `exams/cks-simulation1/solutions.md`
- Modify: `exams/cks-simulation1/scoring-functions.sh`

No `setup.sh` changes: `monitoring` namespace already exists from Task 2.

- [ ] **Step 1: Append the question to questions.md**

```markdown
## Question 11 | Falco Runtime Security | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | Monitoring, Logging and Runtime Security     |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | `monitoring`                                 |
| **File to create**  | `./exam/course/11/falco-alert.txt`           |

### Task

Deploy Falco via Helm into the `monitoring` namespace. Once it's running,
trigger a runtime security event (e.g. get an interactive shell in any
running container with `kubectl exec -it ... -- sh`, which trips Falco's
built-in "Terminal shell in container" rule), then save the matching alert
line from the Falco pod's logs to `./exam/course/11/falco-alert.txt`.

---
```

- [ ] **Step 2: Append the solution to solutions.md**

```markdown
## Question 11 | Falco Runtime Security

**Solution:**

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco -n monitoring --kube-context cks-dojo \
  --set tty=true --set driver.kind=modern_ebpf

kubectl --context cks-dojo -n monitoring rollout status daemonset/falco --timeout=120s

# trigger the rule
kubectl --context cks-dojo -n workload-security exec -it deploy/hardened-app -- sh -c "echo triggered" || true

FALCO_POD=$(kubectl --context cks-dojo -n monitoring get pods -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}')
kubectl --context cks-dojo -n monitoring logs "$FALCO_POD" | grep -i "warning" | tail -n1 \
  > ./exam/course/11/falco-alert.txt
```

**Explanation:** Falco ships with a default ruleset that flags interactive
shells inside containers as suspicious runtime behavior; capturing that
alert from its logs is the standard way to prove runtime detection is
actually working, not just installed.

---
```

- [ ] **Step 3: Insert score_q11 into scoring-functions.sh**

```bash
score_q11() {
	print_header "Question 11 | Falco Runtime Security (8 points)"
	local score=0
	local ns="monitoring"

	local falco_pod
	falco_pod=$("${KCTL[@]}" -n "$ns" get pods -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
	local falco_running="false"
	if [ -n "$falco_pod" ] && [ "$("${KCTL[@]}" -n "$ns" get pod "$falco_pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; then
		falco_running="true"
	fi
	check_criterion "Falco is deployed and Running in $ns" "$falco_running" && ((score += 4))

	local evidence="$LOCAL_EXAM_DIR/11/falco-alert.txt"
	local evidence_saved="false"
	[ -s "$evidence" ] && grep -qi "warning" "$evidence" && evidence_saved="true"
	check_criterion "A captured Falco alert is saved to exam/course/11/falco-alert.txt" "$evidence_saved" && ((score += 4))

	Q11_SCORE=$score
	echo "  Question 11 score: $score / 8"
}
```

- [ ] **Step 4: Dogfood - solved and unsolved states**

Apply the solution, run `./run-scoring.sh`, confirm `Q11_SCORE=8`.
Delete the evidence file (leave Falco running, since uninstalling/reinstalling it is slow), rerun, confirm the second check fails and `Q11_SCORE=4`. Recreate the evidence file.

- [ ] **Step 5: Commit**

```bash
git add exams/cks-simulation1/questions.md exams/cks-simulation1/solutions.md exams/cks-simulation1/scoring-functions.sh
git commit -m "Add cks-simulation1 question 11: Falco runtime security"
```

---

## Task 14: README, full end-to-end validation, cleanup

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
# cks-dojo

A minimal, local CKS (Certified Kubernetes Security Specialist) exam simulator,
inspired by [ckad-dojo](https://github.com/TiPunchLabs/ckad-dojo). No CLI, no
web UI - just questions, an idempotent setup script, and bash-based scoring,
run against a dedicated multi-node minikube cluster.

## Quick start

1. Read [PREREQUISITES.md](PREREQUISITES.md) and start the cluster.
2. `cd exams/cks-simulation1 && ./setup.sh`
3. Solve each question in `./exam/course/<question-number>/` (see `questions.md`).
4. `./run-scoring.sh`
5. Stuck? Check `solutions.md`.

## What's here

- `exams/cks-simulation1/` - 11 questions across all six CKS curriculum domains
  (Cluster Setup, Cluster Hardening, System Hardening, Minimize Microservice
  Vulnerabilities, Supply Chain Security, Monitoring/Logging/Runtime Security).
  92 points total, ~66% (61 points) to pass.
- `scripts/lib/common.sh` - shared print/scoring helpers used by every exam.

## Known limitations (v1)

- Targets multi-node minikube + Calico only (see PREREQUISITES.md). Other
  cluster targets aren't supported yet.
- No AppArmor questions - seccomp is used instead, since it works identically
  across all supported hosts (see PREREQUISITES.md for why).
- No CLI wrapper or web UI. No automated timer; self-time against the 120
  minutes noted in `exam.conf`.
```

- [ ] **Step 2: Full end-to-end dogfood run**

With every question already left in its solved state from Tasks 3-13, run:

```bash
cd exams/cks-simulation1 && ./run-scoring.sh
```

Expected: `TOTAL: 92 / 92 -- PASS (threshold: 61)`.

- [ ] **Step 3: Full end-to-end negative run**

Tear down every solution applied in Tasks 3-13 (delete the created RBAC/NetworkPolicy/Deployment/Pod/Job resources, remove the namespace label, revert the three kube-apiserver flags together, delete all `exam/course/*` files), then rerun:

```bash
./run-scoring.sh
```

Expected: `TOTAL: 0 / 92 -- FAIL (threshold: 61)`.

- [ ] **Step 4: Restore the solved state**

Reapply every solution from Tasks 3-13 (audit policy, NetworkPolicies, RBAC,
kubelet hardening, seccomp pod, kube-bench remediation, hardened Deployment,
PSA label, supply-chain Deployment, encryption config, Falco alert evidence)
so the repository's documented "happy path" is left in a fully verified,
working state.

Run `./run-scoring.sh` one more time.
Expected: `TOTAL: 92 / 92 -- PASS (threshold: 61)`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Add cks-dojo README; cks-simulation1 fully validated end to end"
```

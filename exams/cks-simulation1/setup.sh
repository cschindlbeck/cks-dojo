#!/bin/bash
set -euo pipefail

EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EXAM_DIR/../.." && pwd)"
source "$EXAM_DIR/exam.conf"

KCTL=(kubectl --context "$MINIKUBE_PROFILE")

RESET=false
for arg in "$@"; do
	case "$arg" in
	--reset) RESET=true ;;
	*)
		echo "Error: unknown option '$arg' (expected '--reset')" >&2
		exit 1
		;;
	esac
done

echo "Setting up $EXAM_NAME on minikube profile '$MINIKUBE_PROFILE'..."

for ns in "${EXAM_NAMESPACES[@]}"; do
	"${KCTL[@]}" create namespace "$ns" --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
done

mkdir -p "$REPO_ROOT/exam/course"
for i in $(seq 1 "$TOTAL_QUESTIONS"); do
	if [ "$RESET" = "true" ]; then
		# Remove answer files from a previous attempt, so stale evidence
		# cannot earn points on a fresh run.
		find "$REPO_ROOT/exam/course/$i" -mindepth 1 -delete 2>/dev/null || true
	fi
	mkdir -p "$REPO_ROOT/exam/course/$i"
done

# === QUESTION SEED RESOURCES (one block per question, appended below) ===

# --- Question 2: net-hardening seed workloads ---
"${KCTL[@]}" -n net-hardening create deployment backend --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening expose deployment backend --port=80 --target-port=80 --name=backend-svc --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening create deployment frontend --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening rollout status deployment/backend --timeout=60s
"${KCTL[@]}" -n net-hardening rollout status deployment/frontend --timeout=60s

# --- Question 3: rbac-lab seed resources ---
"${KCTL[@]}" -n rbac-lab create serviceaccount viewer-bot --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n rbac-lab create configmap app-config --from-literal=env=staging --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n rbac-lab create deployment sample-app --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

# --- Question 4: kubelet-m02 anonymous auth intentionally misconfigured ---
# This minikube profile's kubeadm-generated kubelet config ships with
# authentication.anonymous.enabled: false out of the box, unlike a typical
# real-world/exam cluster where it defaults to enabled. Deliberately flip it
# to true on the worker node so the candidate has genuine hardening work to
# do. Idempotent: only edits + restarts kubelet if not already misconfigured
# this way.
WORKER_NODE="${MINIKUBE_PROFILE}-m02"
anon_enabled="false"
if minikube ssh -p "$MINIKUBE_PROFILE" -n "$WORKER_NODE" -- \
	"sudo grep -A1 'anonymous:' /var/lib/kubelet/config.yaml" 2>/dev/null | grep -q "enabled: true"; then
	anon_enabled="true"
fi
if [ "$anon_enabled" != "true" ]; then
	echo "  Question 4: enabling kubelet anonymous auth on $WORKER_NODE (intentional misconfiguration)..."
	minikube ssh -p "$MINIKUBE_PROFILE" -n "$WORKER_NODE" -- \
		"sudo sed -i '/anonymous:/{n;s/enabled: false/enabled: true/}' /var/lib/kubelet/config.yaml"
	minikube ssh -p "$MINIKUBE_PROFILE" -n "$WORKER_NODE" -- "sudo systemctl restart kubelet"
	kubelet_status=""
	for i in $(seq 1 15); do
		kubelet_status=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$WORKER_NODE" -- "systemctl is-active kubelet" 2>/dev/null | tr -d '\r') || true
		if [ "$kubelet_status" = "active" ]; then
			break
		fi
		sleep 2
	done
	if [ "$kubelet_status" != "active" ]; then
		echo "  WARNING: kubelet on $WORKER_NODE did not become active after restart" >&2
	fi
else
	echo "  Question 4: kubelet anonymous auth already enabled on $WORKER_NODE, skipping."
fi

# --- Question 5: seccomp profile installed on every node ---
SECCOMP_PROFILE="$EXAM_DIR/manifests/setup/deny-chmod.json"
for node in "$MINIKUBE_PROFILE" "${MINIKUBE_PROFILE}-m02"; do
	minikube ssh -p "$MINIKUBE_PROFILE" -n "$node" -- "sudo mkdir -p /var/lib/kubelet/seccomp/profiles"
	minikube cp -p "$MINIKUBE_PROFILE" "$SECCOMP_PROFILE" "${node}:/var/lib/kubelet/seccomp/profiles/deny-chmod.json"
done

# === END QUESTION SEED RESOURCES ===

echo "Setup complete."

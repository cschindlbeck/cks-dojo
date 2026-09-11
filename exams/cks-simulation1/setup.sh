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

# --- Question 2: net-hardening seed workloads ---
"${KCTL[@]}" -n net-hardening create deployment backend --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening expose deployment backend --port=80 --target-port=80 --name=backend-svc --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening create deployment frontend --image=nginx:1.25-alpine --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
"${KCTL[@]}" -n net-hardening rollout status deployment/backend --timeout=60s
"${KCTL[@]}" -n net-hardening rollout status deployment/frontend --timeout=60s

# === END QUESTION SEED RESOURCES ===

echo "Setup complete."

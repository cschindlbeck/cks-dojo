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

score_q2() {
	print_header "Question 2 | NetworkPolicy Default Deny (10 points)"
	local score=0
	local ns="net-hardening"

	local netpol_count
	netpol_count=$("${KCTL[@]}" -n "$ns" get networkpolicy -o name 2>/dev/null | wc -l | tr -d ' ')
	check_criterion "At least one NetworkPolicy exists in $ns" \
		"$([ "$netpol_count" -ge 1 ] && echo true || echo false)" && ((score += 2))

	local has_default_deny="false"
	# Correlated check on the SAME policy object: an empty podSelector only denies
	# all ingress if that policy's policyTypes actually includes "Ingress" - a
	# policy with podSelector:{} and policyTypes:[Egress] denies nothing on ingress
	# and must not be credited as default-deny.
	if "${KCTL[@]}" -n "$ns" get networkpolicy -o json 2>/dev/null | \
		jq -e '.items[] | select(.spec.podSelector == {} and (.spec.policyTypes // [] | any(. == "Ingress")))' \
		>/dev/null 2>&1; then
		has_default_deny="true"
	fi
	check_criterion "A default-deny-all NetworkPolicy is present" "$has_default_deny" && ((score += 2))

	local allowed="false"
	if "${KCTL[@]}" -n "$ns" run netpol-test-allowed --rm -i --restart=Never --image=busybox:1.36 \
		--overrides='{"apiVersion":"v1","metadata":{"labels":{"app":"frontend"}},"spec":{"containers":[{"name":"netpol-test-allowed","image":"busybox:1.36","command":["wget","-q","-T","5","-O-","http://backend-svc"]}]}}' \
		2>/dev/null; then
		allowed="true"
	fi
	# Only credit-worthy when a default-deny policy is actually in effect - otherwise
	# a candidate with NO NetworkPolicy at all would get these points for Calico's
	# default-allow behavior, which is a false positive, not evidence of the solution.
	if check_criterion "frontend pods can reach backend-svc:80" "$allowed" && [ "$has_default_deny" = "true" ]; then
		((score += 3))
	fi

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

# === END SCORING FUNCTIONS ===

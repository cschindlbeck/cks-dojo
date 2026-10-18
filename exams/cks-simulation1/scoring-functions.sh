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
		>/dev/null 2>&1; then
		allowed="true"
	fi
	# Only credit-worthy when a default-deny policy is actually in effect - otherwise
	# a candidate with NO NetworkPolicy at all would get these points for Calico's
	# default-allow behavior, which is a false positive, not evidence of the solution.
	if check_criterion "frontend pods can reach backend-svc:80" "$allowed" && [ "$has_default_deny" = "true" ]; then
		((score += 3))
	fi

	# Credit the block only if the test pod actually ran and wget failed inside it.
	# A pod that never starts (e.g. broken CNI) also makes kubectl exit non-zero,
	# which must not be mistaken for a NetworkPolicy block. The container prints a
	# marker so "blocked" needs positive evidence, not just a failed kubectl run.
	local blocked="false"
	local blocked_out
	blocked_out=$("${KCTL[@]}" -n "$ns" run netpol-test-blocked --rm -i --restart=Never --image=busybox:1.36 \
		--overrides='{"apiVersion":"v1","metadata":{"labels":{"app":"other"}},"spec":{"containers":[{"name":"netpol-test-blocked","image":"busybox:1.36","command":["sh","-c","wget -q -T 5 -O- http://backend-svc >/dev/null 2>&1 && echo NETPOL_REACHED || echo NETPOL_BLOCKED"]}]}}' \
		2>/dev/null)
	if grep -q NETPOL_BLOCKED <<<"$blocked_out"; then
		blocked="true"
	fi
	check_criterion "pods without app=frontend cannot reach backend-svc:80" "$blocked" && ((score += 3))

	Q2_SCORE=$score
	echo "  Question 2 score: $score / 10"
}

score_q3() {
	print_header "Question 3 | RBAC Least Privilege (8 points)"
	local score=0
	local ns="rbac-lab"
	local sa="system:serviceaccount:${ns}:viewer-bot"

	local role_exists="false"
	"${KCTL[@]}" -n "$ns" get role -o name 2>/dev/null | grep -q . && role_exists="true"

	local binding_exists="false"
	"${KCTL[@]}" -n "$ns" get rolebinding -o name 2>/dev/null | grep -q . && binding_exists="true"

	local can_get_pods="false"
	[ "$("${KCTL[@]}" auth can-i get pods -n "$ns" --as="$sa" 2>/dev/null)" = "yes" ] && can_get_pods="true"

	local can_get_cm="false"
	[ "$("${KCTL[@]}" auth can-i get configmaps -n "$ns" --as="$sa" 2>/dev/null)" = "yes" ] && can_get_cm="true"

	# Some Role/RoleBinding existing ANYWHERE in the namespace is not evidence
	# of a real solution by itself - a candidate could create a totally
	# unrelated Role (e.g. granting access to a different resource) and an
	# unrelated RoleBinding (e.g. binding a different subject), which would
	# satisfy "exists" checks without ever granting viewer-bot anything. Tie
	# credit to viewer-bot actually having demonstrated, relevant access
	# (get on pods and/or configmaps), not mere object existence.
	local has_real_access="false"
	{ [ "$can_get_pods" = "true" ] || [ "$can_get_cm" = "true" ]; } && has_real_access="true"

	local role_credit="false"
	[ "$role_exists" = "true" ] && [ "$has_real_access" = "true" ] && role_credit="true"
	check_criterion "A Role exists in $ns and grants viewer-bot real access" "$role_credit" && ((score += 1))

	local binding_credit="false"
	[ "$binding_exists" = "true" ] && [ "$has_real_access" = "true" ] && binding_credit="true"
	check_criterion "A RoleBinding exists in $ns and grants viewer-bot real access" "$binding_credit" && ((score += 1))

	check_criterion "viewer-bot can get pods" "$can_get_pods" && ((score += 2))

	check_criterion "viewer-bot can get configmaps" "$can_get_cm" && ((score += 2))

	# "cannot create pods" / "cannot get secrets" are true by default for ANY
	# ServiceAccount with no relevant Role/RoleBinding at all - crediting them
	# unconditionally would award points in a genuinely unsolved state (or in
	# the unrelated-RBAC-objects case above). Only credit them when viewer-bot
	# actually has real, relevant access, so they reward the candidate scoping
	# their grant narrowly rather than doing nothing (or something irrelevant).
	local has_rbac="$has_real_access"

	local cannot_create_pods="false"
	[ "$("${KCTL[@]}" auth can-i create pods -n "$ns" --as="$sa" 2>/dev/null)" = "no" ] && cannot_create_pods="true"
	if check_criterion "viewer-bot cannot create pods (least privilege)" "$cannot_create_pods" && [ "$has_rbac" = "true" ]; then
		((score += 1))
	fi

	local cannot_get_secrets="false"
	[ "$("${KCTL[@]}" auth can-i get secrets -n "$ns" --as="$sa" 2>/dev/null)" = "no" ] && cannot_get_secrets="true"
	if check_criterion "viewer-bot cannot get secrets (least privilege)" "$cannot_get_secrets" && [ "$has_rbac" = "true" ]; then
		((score += 1))
	fi

	Q3_SCORE=$score
	echo "  Question 3 score: $score / 8"
}

score_q4() {
	print_header "Question 4 | Kubelet Hardening (8 points)"
	local score=0
	local node="${MINIKUBE_PROFILE}-m02"

	local local_copy="$LOCAL_EXAM_DIR/4/kubelet-config.yaml"
	check_criterion "Local copy of kubelet config saved" \
		"$([ -f "$local_copy" ] && echo true || echo false)" && ((score += 1))

	# setup.sh deliberately misconfigures authentication.anonymous.enabled to
	# true on this node (see the Question 4 block in setup.sh), so both of
	# these checks are genuine, non-trivial signals of candidate action -
	# neither is true on a freshly-provisioned, untouched node.
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
		# Must be exactly 401, not 403: with anonymous.enabled true, the request
		# still authenticates as system:anonymous and only then gets denied by
		# RBAC/webhook authorization (403 Forbidden) - that's a false positive,
		# since it happens regardless of the kubelet-level anonymous setting.
		# Only a 401 means the kubelet's own authentication layer rejected the
		# unauthenticated request outright, which only happens when
		# anonymous.enabled is actually false.
		local http_code
		http_code=$(minikube ssh -p "$MINIKUBE_PROFILE" -n "$MINIKUBE_PROFILE" -- \
			"curl -sk -o /dev/null -w '%{http_code}' https://${node_ip}:10250/pods --max-time 5" 2>/dev/null | tr -d '\r')
		[ "$http_code" = "401" ] && anon_rejected="true"
	fi
	check_criterion "Anonymous kubelet API access is rejected" "$anon_rejected" && ((score += 2))

	Q4_SCORE=$score
	echo "  Question 4 score: $score / 8"
}

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

	# Captured via command substitution rather than piped directly into grep:
	# run-scoring.sh runs with `set -o pipefail`, and kubectl exec's own exit
	# code mirrors the remote command's exit code (1 when chmod is blocked).
	# Piping straight into grep would make that non-zero exit code win the
	# pipefail race even when grep matches, silently scoring the genuinely
	# solved state as 0 - capturing output first avoids the pipe entirely.
	local chmod_output
	chmod_output=$("${KCTL[@]}" -n "$ns" exec "$pod" -- chmod 777 /tmp 2>&1)
	local chmod_blocked="false"
	echo "$chmod_output" | grep -qi "not permitted" && chmod_blocked="true"
	check_criterion "chmod is blocked inside the pod by the profile" "$chmod_blocked" && ((score += 2))

	local evidence_saved="false"
	[ -s "$LOCAL_EXAM_DIR/5/seccomp-test.txt" ] && evidence_saved="true"
	check_criterion "Evidence saved to exam/course/5/seccomp-test.txt" "$evidence_saved" && ((score += 1))

	Q5_SCORE=$score
	echo "  Question 5 score: $score / 8"
}

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

score_q8() {
	print_header "Question 8 | Pod Security Admission (8 points)"
	local score=0
	local ns="psa-lab"

	local enforce_label
	enforce_label=$("${KCTL[@]}" get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
	check_criterion "Namespace labeled pod-security.kubernetes.io/enforce=restricted" \
		"$([ "$enforce_label" = "restricted" ] && echo true || echo false)" && ((score += 3))

	# Output captured before grepping (see score_q5): a rejected apply exits
	# non-zero, which would win the pipefail race and hide the match.
	local bad_pod_output
	bad_pod_output=$("${KCTL[@]}" apply -f "$EXAM_DIR/templates/bad-pod.yaml" 2>&1)
	local bad_pod_rejected="false"
	echo "$bad_pod_output" | grep -qi "violat" && bad_pod_rejected="true"
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

score_q9() {
	print_header "Question 9 | Image Vulnerability Scanning (10 points)"
	local score=0
	local ns="supply-chain"

	# Require a real trivy JSON report for node:14 with at least one CRITICAL
	# vulnerability, not just any non-empty file containing the word CRITICAL.
	local report="$LOCAL_EXAM_DIR/9/trivy-report.json"
	local report_valid="false"
	[ -s "$report" ] && jq -e '.ArtifactName == "node:14" and ([.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length > 0)' \
		"$report" >/dev/null 2>&1 && report_valid="true"
	check_criterion "trivy report for node:14 saved and shows CRITICAL findings" "$report_valid" && ((score += 4))

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

	# Always write a fresh Secret: an existing one is only re-encrypted when it
	# is actually rewritten, and an identical `apply` is a no-op. Deleting first
	# makes the check depend on the live apiserver config, not on when the
	# Secret happened to be created.
	"${KCTL[@]}" -n default delete secret cks-secret --ignore-not-found >/dev/null 2>&1
	"${KCTL[@]}" -n default create secret generic cks-secret --from-literal=password=SuperSecret123 >/dev/null 2>&1

	local etcd_pod
	etcd_pod=$("${KCTL[@]}" -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

	local raw_value=""
	local encrypted="false"
	if [ -n "$etcd_pod" ]; then
		# The etcd image is distroless (no sh), and minikube keeps the etcd certs
		# under /var/lib/minikube/certs, so call etcdctl directly with those paths.
		raw_value=$("${KCTL[@]}" -n kube-system exec "$etcd_pod" -- etcdctl \
			--cacert=/var/lib/minikube/certs/etcd/ca.crt \
			--cert=/var/lib/minikube/certs/etcd/server.crt \
			--key=/var/lib/minikube/certs/etcd/server.key \
			get /registry/secrets/default/cks-secret 2>/dev/null)
		echo "$raw_value" | grep -aq "k8s:enc:" && encrypted="true"
	fi
	check_criterion "cks-secret is stored encrypted in etcd (k8s:enc: prefix)" "$encrypted" && ((score += 4))

	# Only credit this when etcd was actually read, otherwise an unreachable
	# etcd would look like "plaintext absent".
	local plaintext_absent="false"
	if [ -n "$raw_value" ] && ! echo "$raw_value" | grep -aq "SuperSecret123"; then
		plaintext_absent="true"
	fi
	check_criterion "Secret plaintext value is not visible in raw etcd output" "$plaintext_absent" && ((score += 1))

	Q10_SCORE=$score
	echo "  Question 10 score: $score / 8"
}

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

	# Falco's "Terminal shell in container" rule logs at Notice priority with
	# the text "A shell was spawned in a container with an attached terminal",
	# so match that text rather than a severity word. The saved line must also
	# exist in the live Falco logs (one pod per node), so a hand-typed or
	# unrelated file does not earn credit.
	local evidence="$LOCAL_EXAM_DIR/11/falco-alert.txt"
	local evidence_saved="false"
	if [ -s "$evidence" ]; then
		local alert_line
		alert_line=$(grep -i -m1 "shell was spawned in a container" "$evidence" | tr -d '\r')
		if [ -n "$alert_line" ]; then
			local falco_logs
			falco_logs=$("${KCTL[@]}" -n "$ns" logs -l app.kubernetes.io/name=falco -c falco --tail=-1 2>/dev/null)
			echo "$falco_logs" | grep -qF -- "$alert_line" && evidence_saved="true"
		fi
	fi
	check_criterion "A captured Falco alert is saved to exam/course/11/falco-alert.txt" "$evidence_saved" && ((score += 4))

	Q11_SCORE=$score
	echo "  Question 11 score: $score / 8"
}

# === END SCORING FUNCTIONS ===

# CKS Simulation 1 - Solutions

This document contains the solutions for all 11 questions in CKS Simulation 1.

---

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

**Note on this cluster:** this minikube profile's kubeadm-generated
`/var/lib/kubelet/config.yaml` ships with `authentication.anonymous.enabled:
false` by default, unlike a typical real-world/exam cluster where it defaults
to enabled. `setup.sh` deliberately flips it to `true` on `cks-dojo-m02`
before the exam starts, so this question presents the same genuine
hardening task a candidate would face on a real cluster.

---

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


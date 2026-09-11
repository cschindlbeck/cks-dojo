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

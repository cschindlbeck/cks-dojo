# CKS Simulation 1

> **Total Score**: 92 points | **Passing Score**: ~66% (61 points)
>
> Recommended duration: 120 minutes, self-timed (no automated timer in this version).
>
> Run `./setup.sh` first, solve each question under `./exam/course/N/` (mirrors the
> real exam's `/opt/course/N/` convention), then run `./run-scoring.sh`.

---

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

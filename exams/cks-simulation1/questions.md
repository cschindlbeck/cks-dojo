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
## Question 6 | kube-bench Remediation | 6 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 6                                            |
| **CKS Domain**      | System Hardening                             |
| **CKS Weight**      | 15%                                          |
| **Namespace**       | -                                            |
| **File to create**  | `./exam/course/6/kube-bench-report.txt`      |

### Task

Run kube-bench against the control-plane node using the provided
`./exams/cks-simulation1/templates/kube-bench-job.yaml`, and save its output to
`./exam/course/6/kube-bench-report.txt`.

Then remediate the finding about kube-apiserver profiling by adding
`--profiling=false` to the kube-apiserver static pod manifest (alongside the
audit flags already added in Question 1 - do not remove them).

---

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

## Question 8 | Pod Security Admission | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | Minimize Microservice Vulnerabilities        |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | `psa-lab`                                    |
| **Resources**       | Namespace label                              |
| **File to create**  | -                                            |

### Task

Label the `psa-lab` namespace to enforce the `restricted` Pod Security
Standard. Confirm `./exams/cks-simulation1/templates/bad-pod.yaml` (a privileged Pod) is rejected
once the label is applied.

---

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

## Question 10 | etcd Encryption at Rest | 8 points

|                     |                                              |
| ------------------- | -------------------------------------------- |
| **Points**          | 8                                            |
| **CKS Domain**      | Supply Chain Security                        |
| **CKS Weight**      | 20%                                          |
| **Namespace**       | -                                            |
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
trigger a runtime security event (e.g. get an interactive shell in any running
container with `kubectl exec -it ... -- sh`, which trips Falco's built-in
"Terminal shell in container" rule), then save the matching alert line from
the Falco pod's logs to `./exam/course/11/falco-alert.txt`.

---


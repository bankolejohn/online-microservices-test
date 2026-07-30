# Incident Response and Troubleshooting Guide

## The #1 Rule

**Restore service first, investigate second.**

Users don't care why it's broken. They care that it's fixed. A senior engineer reverts in 60 seconds, gets users back online, THEN spends time understanding root cause — calmly, with no pressure.

---

## Incident Priority Order

| Step | Action | Time target |
|------|--------|-------------|
| 1. Mitigate | Rollback, revert, scale up, failover | < 5 minutes |
| 2. Communicate | Update status page, notify stakeholders | < 10 minutes |
| 3. Investigate | Find root cause (service is already restored) | 30-60 minutes |
| 4. Fix properly | Permanent fix via PR, tested, deployed through CI/CD | Hours/days |
| 5. Post-mortem | Document what happened, why, how to prevent | Within 48 hours |

The mistake junior engineers make: they debug for 45 minutes while users are down. A senior restores in 60 seconds.

---

## Quick Rollback Commands (memorize these)

```bash
# Option 1: ArgoCD sync to last known good state (fastest)
argocd app sync online-shopping-staging

# Option 2: Git revert the last deployment
git revert HEAD
git push origin main
# ArgoCD picks up the revert within 3 minutes

# Option 3: Kubernetes rollback (immediate, no git change)
kubectl rollout undo deployment/checkout-service -n shopping

# Option 4: ArgoCD rollback to specific revision
argocd app rollback online-shopping-staging <revision-number>

# Option 5: etcd restore (nuclear option — full cluster state rollback)
./scripts/etcd-restore.sh backups/etcd-snapshot-YYYYMMDD-HHMMSS.db
```

---

## Troubleshooting Frameworks

### The "Outside-In" Method (most common for Kubernetes)

Start from the user's perspective and work inward:

```
User symptom → Service → Pods → Containers → Application → Dependencies
```

| Layer | What to check | Commands |
|-------|--------------|----------|
| 1. Symptoms | What do users see? What endpoint fails? | `curl`, browser, status page |
| 2. Scope | One service? All services? One region? | `kubectl get pods -A`, check other services |
| 3. Timeline | When did it start? What changed? | `git log`, `argocd app history`, `kubectl get events` |
| 4. Service | Does the Kubernetes Service have endpoints? | `kubectl get endpoints <svc>` |
| 5. Pods | Are pods Running? CrashLooping? Pending? | `kubectl get pods -l app=<service>` |
| 6. Resources | CPU/memory exhaustion? OOM kills? | `kubectl top pods`, `kubectl describe pod` |
| 7. Networking | Can pods reach each other? DNS working? | `kubectl exec -- nslookup <service>`, `curl` |
| 8. Application | What do the logs say? | `kubectl logs deployment/<service>` |
| 9. Config | Are env vars correct? ConfigMaps right? | `kubectl set env deployment/<service> --list` |
| 10. Dependencies | Is an upstream service broken? | Check payment, shipping, database |

### The USE Method (for resource issues)

- **U**tilization — is a resource maxed out? (CPU 100%? Memory full? Disk full?)
- **S**aturation — is work queuing? (pods Pending? request latency spiking?)
- **E**rrors — are there error counts? (5xx responses? OOM kills? crash loops?)

```bash
# Utilization
kubectl top pods -n shopping
kubectl top nodes
docker stats --no-stream  # For Kind nodes

# Saturation
kubectl get pods -n shopping --field-selector=status.phase=Pending
kubectl get events -n shopping --sort-by=.lastTimestamp | tail -20

# Errors
kubectl get pods -n shopping | grep -E "Error|CrashLoop|ImagePull"
kubectl logs deployment/<service> -n shopping | grep -i error
```

### The RED Method (for service-level issues)

- **R**ate — how many requests per second? (is traffic normal or spiking?)
- **E**rrors — what percentage of requests are failing? (error rate)
- **D**uration — how long do requests take? (latency)

```bash
# If Prometheus is running:
# Rate
rate(http_requests_total{namespace="shopping"}[5m])

# Errors
rate(http_requests_total{namespace="shopping",status=~"5.."}[5m])

# Duration
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
```

---

## Common Incident Scenarios and Diagnosis

### Scenario 1: Pod CrashLoopBackOff

**Symptom:** Pod keeps restarting, never stays Running.

```bash
# Step 1: Check pod status and restart count
kubectl get pods -n shopping -l app=<service>

# Step 2: Check why it's crashing (exit code + logs)
kubectl describe pod <pod-name> -n shopping | grep -A5 "Last State"
kubectl logs <pod-name> -n shopping --previous  # Logs from the CRASHED container

# Step 3: Common causes
# - Exit code 1: application error (bad config, missing env var)
# - Exit code 137: OOM killed (needs more memory)
# - Exit code 143: SIGTERM (graceful shutdown — usually normal during rollout)
```

### Scenario 2: ImagePullBackOff

**Symptom:** Pod stuck in ImagePullBackOff, never starts.

```bash
# Step 1: Check what image it's trying to pull
kubectl describe pod <pod-name> -n shopping | grep "Image:"

# Step 2: Check the error message
kubectl describe pod <pod-name> -n shopping | grep -A3 "Failed"

# Common causes:
# - 403 Forbidden: missing imagePullSecrets (registry auth)
# - Image not found: wrong tag or image doesn't exist
# - Timeout: network issue or registry down
```

### Scenario 3: Service returns 502/503

**Symptom:** Users get errors but pods look healthy.

```bash
# Step 1: Check if endpoints exist for the Service
kubectl get endpoints <service-name> -n shopping
# If EMPTY → Service selector doesn't match pod labels

# Step 2: Check if readiness probe is passing
kubectl describe pod <pod-name> -n shopping | grep -A5 "Conditions"
# If Ready=False → readiness probe failing → pod removed from Service endpoints

# Step 3: Check application config (most common cause!)
kubectl set env deployment/<service> -n shopping --list
# Look for wrong URLs, missing credentials, bad connection strings

# Step 4: Test connectivity from inside the mesh
kubectl exec deployment/<service> -n shopping -c <container> -- \
  curl -s http://<target-service>:<port>/health
```

### Scenario 4: High latency (slow but not broken)

**Symptom:** Requests succeed but take 10-30 seconds instead of <1 second.

```bash
# Step 1: Check resource pressure
kubectl top pods -n shopping --sort-by=cpu
kubectl top nodes

# Step 2: Check if HPA is scaling (demand exceeding capacity?)
kubectl get hpa -n shopping

# Step 3: Check Istio circuit breakers (is traffic being throttled?)
kubectl get destinationrules -n shopping -o yaml | grep -A10 "outlierDetection"

# Step 4: Check for resource throttling
kubectl describe pod <pod-name> -n shopping | grep -A5 "Limits"
# If CPU limit is 200m and pod is using 200m → being throttled
```

### Scenario 5: Complete cluster unreachable

**Symptom:** `kubectl` returns "connection refused" or "TLS handshake timeout."

```bash
# Step 1: Is Docker/containerd running?
docker ps | grep shopping-cluster

# Step 2: Is the API server container alive?
docker exec shopping-cluster-control-plane crictl ps | grep kube-apiserver

# Step 3: Resource saturation (thundering herd after restart)
docker stats --no-stream | grep shopping

# Step 4: If API server is dead, check its logs
docker exec shopping-cluster-control-plane crictl logs $(docker exec shopping-cluster-control-plane crictl ps -a | grep kube-apiserver | awk '{print $1}')

# Step 5: etcd alive?
docker exec shopping-cluster-control-plane crictl ps | grep etcd
```

---

## Incident Simulation: Misconfigured Payment Service URL

### The scenario (what we tested)

**Alert:** "Checkout error rate > 50% for 5 minutes"
**User report:** "I can browse products and add to cart, but checkout fails with 'payment processing failed'"

### The investigation

| Step | What we checked | What we found |
|------|----------------|---------------|
| 1 | `kubectl get svc checkout-service -n shopping` | Service exists, has ClusterIP ✅ |
| 2 | `kubectl get endpoints checkout-service -n shopping` | Endpoints exist, pods are backing it ✅ |
| 3 | `kubectl get pods -l app=checkout-service -n shopping` | Pods are 2/2 Running ✅ |
| 4 | `kubectl logs deployment/checkout-service -n shopping` | No obvious crash (app started fine) ✅ |
| 5 | `kubectl set env deployment/checkout-service -n shopping --list` | **FOUND IT** ❌ |

**Root cause:** `PAYMENT_SERVICE_URL` was overridden with a non-existent hostname:
```
PAYMENT_SERVICE_URL=http://payment-service-DOES-NOT-EXIST:5002
```

### Why it was hard to find

- Pods were Running (not crashing — the app starts fine, it only fails when processing a checkout)
- Service and Endpoints looked healthy
- Infrastructure was perfect — the bug was in APPLICATION CONFIGURATION
- You'd only see the error if you triggered an actual checkout request or checked env vars

### The fix

```bash
# Quick fix: remove the bad override (ConfigMap takes over)
kubectl set env deployment/checkout-service -n shopping PAYMENT_SERVICE_URL-

# Proper fix: ArgoCD sync (restores git state)
argocd app sync online-shopping-staging

# Prevention: ArgoCD self-heal (catches drift automatically)
# Already configured — we just had to re-enable it after the drill
```

### Key lesson

Infrastructure looking "green" doesn't mean the application works. The most common production incidents are misconfigurations — a wrong URL, a missing env var, an expired credential. Pods are Running but the app can't do its job.

---

## Post-Mortem Template

After every P1/P2 incident, write a post-mortem. No blame — just facts and improvements.

```markdown
## Incident Post-Mortem: [Title]

**Date:** YYYY-MM-DD
**Duration:** X minutes (time from alert to resolution)
**Severity:** P1/P2/P3
**Impact:** [What users experienced]
**On-call engineer:** [Name]

### Timeline

| Time | Event |
|------|-------|
| 01:00 | Alert fired: "Checkout error rate > 50%" |
| 01:02 | On-call acknowledged, started investigation |
| 01:05 | Identified: checkout pods running but payment URL wrong |
| 01:06 | Mitigated: ArgoCD sync restored correct configuration |
| 01:08 | Verified: checkout working, error rate back to 0% |
| 01:10 | All clear communicated to team |

### Root Cause

[What specifically broke and why]

### Resolution

[What was done to fix it]

### Action Items

| Action | Owner | Priority | Due |
|--------|-------|----------|-----|
| Add integration test for checkout→payment connectivity | Dev team | High | This sprint |
| Alert on PAYMENT_SERVICE_URL env var change | Platform | Medium | Next sprint |
| Document rollback procedure in runbook | SRE | Low | This quarter |

### Lessons Learned

- ArgoCD self-heal would have caught this in 3 minutes (was disabled for testing)
- Environment variable overrides bypass ConfigMap governance
- Need better alerting on configuration drift (not just pod health)
```

---

## Runbook: On-Call Quick Reference

When you get paged at 1am, this is your cheat sheet:

```bash
# ===== FIRST 30 SECONDS =====
# What's broken?
kubectl get pods -n shopping | grep -v "Running\|Completed"
kubectl get events -n shopping --sort-by=.lastTimestamp | tail -10

# ===== FIRST 2 MINUTES =====
# How bad is it?
kubectl get pods -n shopping -o wide  # All services or just one?
kubectl top pods -n shopping          # Resource pressure?

# ===== IF ONE SERVICE IS DOWN =====
kubectl logs deployment/<service> -n shopping -c <container> --tail=50
kubectl describe pod <failing-pod> -n shopping | tail -30
kubectl set env deployment/<service> -n shopping --list

# ===== QUICK FIXES (pick one) =====
# Rollback deployment
kubectl rollout undo deployment/<service> -n shopping

# ArgoCD sync (restore git state)
argocd app sync online-shopping-staging

# Restart pods (picks up new config/secrets)
kubectl rollout restart deployment/<service> -n shopping

# Scale up (if traffic spike)
kubectl scale deployment/<service> -n shopping --replicas=5

# ===== IF ENTIRE CLUSTER IS DOWN =====
docker ps | grep shopping        # Are Kind containers alive?
docker restart shopping-cluster-control-plane  # Restart control plane
# Wait 2-3 minutes for API server to recover
```

---

## CKA Troubleshooting (30% of exam)

The CKA dedicates 30% of marks to troubleshooting. You'll be given a broken cluster and asked to fix it. Common scenarios:

| Scenario | What's broken | Fix |
|----------|--------------|-----|
| Node NotReady | kubelet stopped | `systemctl start kubelet` |
| Pods Pending | No nodes with resources | Check resource quotas, node capacity |
| Service no endpoints | Selector mismatch | Fix label selector on Service |
| DNS not resolving | CoreDNS down | Check kube-system pods, restart CoreDNS |
| API server unreachable | Certificate expired or static pod missing | Check `/etc/kubernetes/manifests/` |
| etcd down | Data corruption | Restore from snapshot |
| Scheduler not working | Static pod not running | Check scheduler manifest |

---

## Prevention: What Catches Issues Before Users Notice

| Tool | What it catches | Response time |
|------|----------------|---------------|
| Readiness probes | Unhealthy pods removed from Service | 5-10 seconds |
| HPA | Traffic spikes (auto-scale) | 15-30 seconds |
| ArgoCD self-heal | Configuration drift | 3 minutes |
| Prometheus alerts | Error rate spike, latency increase | 1-5 minutes |
| PDBs | Prevent all replicas dying during maintenance | Immediate |
| Circuit breakers (Istio) | Upstream service failing | Immediate |
| Falco | Suspicious runtime behavior | Milliseconds |

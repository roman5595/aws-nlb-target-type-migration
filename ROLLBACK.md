# Rollback: NLB target migration from `ip` to `instance`

This runbook describes rollback of the in-place AWS Load Balancer Controller migration defined in [RFC.md](./RFC.md).

## What the rollback path means

The old instance target groups are deleted during PR 1. Rollback therefore does not mean switching the listeners back to target groups that have been kept in reserve.

Rollback is a new AWS LBC reconciliation in the opposite direction. AWS LBC must converge to a state in which replacement `instance` target groups are configured, eligible nodes are registered on the Service NodePorts, listeners reference those groups and the IP target groups are removed. The underlying API-call order is asynchronous and not guaranteed. The replacement instance target groups will have new ARNs.

Retaining the NodePorts, `externalTrafficPolicy: Local`, `healthCheckNodePort` and target-node labels in PR 1 preserves the Kubernetes inputs required for that reconciliation. If a failure is detected before listener cutover, the original instance path can still be serving traffic. After listener cutover, the retained fields only make reverse reconciliation possible; they do not keep the deleted target group available. Rollback is not immediate or outage-free, so existing and fresh-connection probes must continue throughout it.

Rollback must be performed through a Git revert or a dedicated rollback PR followed by Argo CD sync. Do not manually create, delete or attach AWS LBC-owned target groups or modify listener actions in AWS.

## Failure during PR 1

Do not merge PR 2. Revert the affected Service to its exact pre-PR 1 state through Argo CD:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-target-node-labels: <original Service-specific value>
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: >-
      target_health_state.unhealthy.connection_termination.enabled=false,target_health_state.unhealthy.draining_interval_seconds=0,deregistration_delay.timeout_seconds=300,deregistration_delay.connection_termination.enabled=true
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Local
  healthCheckNodePort: <original value>
  ports:
    # Restore or retain every original nodePort.
```

Remove `preserve_client_ip.enabled=true` only if it was not part of the original instance-mode attribute set. Restore all other values from the captured pre-change inventory rather than copying example values between Services.

Because NodePorts, `externalTrafficPolicy: Local` and target-node labels are still present, AWS LBC can create replacement instance target groups using the existing NodePorts.

After Argo CD sync, verify:

1. AWS LBC reconciliation has no relevant error.
2. Every replacement target group has `TargetType=instance` and the expected attributes and health check.
3. The expected nodes are registered on the correct NodePort and are healthy.
4. Every listener forwards to the corresponding healthy instance target group.
5. NLB identity, listener identities, subnets and, where applicable, EIPs are unchanged.
6. Fresh and protocol-aware probes pass for every listener and NLB address for at least ten minutes.

Rollback is another asynchronous target-group replacement and can have a client-visible transition interval. Do not declare rollback complete merely because Argo CD reports `Synced`; wait for AWS health and client probes.

## Failure after PR 2

Do not revert PR 1 and PR 2 simultaneously. Rollback must be ordered:

1. Revert PR 2 while retaining `TargetType=ip`: restore `allocateLoadBalancerNodePorts: true`, `externalTrafficPolicy: Local`, all original NodePorts and health-check behavior, and the Service-specific target-node labels.
2. Sync with Argo CD and verify that every required NodePort and `healthCheckNodePort` exists while listeners still use healthy IP target groups.
3. Revert PR 1: restore the exact pre-migration instance target type and target-group attributes.
4. Sync with Argo CD and apply the same instance-target and client-probe validation used for a failure during PR 1.

Do not request instance targets before NodePorts exist. Combining both rollback stages recreates the same ordering risk that the two-PR migration is designed to avoid.

## Rollback decision

Rollback when the IP target groups cannot become healthy, listener-specific fresh connections fail beyond the agreed threshold, client-IP preservation is incorrect, or AWS LBC reconciliation cannot converge.

Closure of an individual pre-cutover long-lived connection is not by itself a rollback trigger if reconnect succeeds and the agreed availability SLO remains satisfied.

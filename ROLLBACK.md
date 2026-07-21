# Rollback

## Important behavior

The old instance target groups are deleted during PR 1. Rollback therefore cannot reuse or switch back to the original target groups.

Rollback triggers another asynchronous AWS LBC reconciliation. AWS LBC creates new instance target groups, registers the nodes on the Service NodePorts and updates the listeners. Rollback is not immediate and can cause a temporary connection outage.

Do not modify AWS LBC-owned target groups or listeners manually. Perform rollback through Git and Argo CD.

## Rollback after PR 1

PR 1 keeps the NodePorts and other instance-mode prerequisites, which makes rollback simpler:

1. Do not merge PR 2.
2. Revert PR 1 in Git.
3. Restore `aws-load-balancer-nlb-target-type: instance` and the original target-group attributes.
4. Sync the change through Argo CD.
5. Wait until AWS LBC creates healthy instance target groups and updates every listener.
6. Run the connection probes and verify that the NLB, listeners and external EIPs have not changed.

Do not consider rollback complete only because Argo CD reports `Synced`. The instance targets must be healthy and the probes must pass.

## Rollback after PR 2

Rollback after PR 2 requires two ordered changes:

1. Revert PR 2 while keeping target type `ip`.
2. Restore `allocateLoadBalancerNodePorts: true`, `externalTrafficPolicy: Local`, the original NodePorts, `healthCheckNodePort` and target-node labels.
3. Sync through Argo CD and verify that the NodePorts exist while the IP target groups are still healthy.
4. Revert PR 1 and restore target type `instance`.
5. Sync through Argo CD and wait for healthy instance target groups.
6. Run the connection probes and verify the AWS resources.

Do not restore the NodePorts and switch to instance targets in one change. That would recreate the same ordering risk avoided by the two-PR migration.

## When to roll back

Rollback if:

- the IP targets do not become healthy;
- new connections keep failing;
- the original client IP is not preserved; or
- AWS LBC cannot complete reconciliation.

An individual long-lived connection closing is not by itself a rollback reason if reconnects work and the agreed availability target is met.

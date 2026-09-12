# Karpenter disruption metrics

Minimal PromQL dashboard for evaluating Karpenter `Underutilized` disruption
windows. The queries target AWS Karpenter `v1.0.10`, which uses Karpenter core
`v1.0.7`.

Add the cluster selector used by your Prometheus setup to every query when a
data source contains more than one cluster.

## Current Karpenter node count

```promql
count(
  karpenter_nodes_allocatable{
    resource_type="cpu",
    nodepool!=""
  }
)
```

Per NodePool:

```promql
count by (nodepool) (
  karpenter_nodes_allocatable{
    resource_type="cpu",
    nodepool!=""
  }
)
```

## Nodes eligible for underutilized disruption

```promql
max(
  karpenter_voluntary_disruption_eligible_nodes{
    reason="underutilized"
  }
)
```

`eligible_nodes` has no `nodepool` label in this version. It counts candidates
before disruption-budget, scheduling, and cost validation, so it is not a
confirmed backlog of removable nodes.

## Eligible nodes as a percentage of all Karpenter nodes

```promql
100 *
max(
  karpenter_voluntary_disruption_eligible_nodes{
    reason="underutilized"
  }
)
/
count(
  karpenter_nodes_allocatable{
    resource_type="cpu",
    nodepool!=""
  }
)
```

## Average underutilized NodeClaims deleted per day over seven days

```promql
sum(
  increase(
    karpenter_nodeclaims_disrupted_total{
      reason="Underutilized"
    }[7d]
  )
) / 7
```

Per NodePool:

```promql
sum by (nodepool) (
  increase(
    karpenter_nodeclaims_disrupted_total{
      reason="Underutilized"
    }[7d]
  )
) / 7
```

This counter increments after a successful NodeClaim deletion API request. The
subsequent drain and instance termination can still be in progress.

## Average underutilized replacement NodeClaims created per day over seven days

```promql
sum(
  increase(
    karpenter_nodeclaims_created_total{
      reason="underutilized"
    }[7d]
  )
) / 7
```

Per NodePool:

```promql
sum by (nodepool) (
  increase(
    karpenter_nodeclaims_created_total{
      reason="underutilized"
    }[7d]
  )
) / 7
```

This includes replacement NodeClaims created by underutilized consolidation,
not nodes provisioned to satisfy new workload demand.

## Average net node reduction per day over seven days

```promql
sum(
  increase(
    karpenter_nodeclaims_disrupted_total{
      reason="Underutilized"
    }[7d]
  )
) / 7
-
sum(
  increase(
    karpenter_nodeclaims_created_total{
      reason="underutilized"
    }[7d]
  )
) / 7
```

A positive result means underutilized consolidation deleted more NodeClaims
than it created as replacements. This measures node-count reduction, not cost
savings; a one-for-one replacement can still lower cost.

## Label casing in Karpenter 1.0.10

The reason label is inconsistent in this version:

| Metric | Required label value |
| --- | --- |
| `karpenter_voluntary_disruption_eligible_nodes` | `reason="underutilized"` |
| `karpenter_nodeclaims_disrupted_total` | `reason="Underutilized"` |
| `karpenter_nodeclaims_created_total` | `reason="underutilized"` |

## Sources

- [Karpenter v1.0 metrics reference](https://karpenter.sh/v1.0/reference/metrics/)
- [Node metric definitions and labels](https://github.com/kubernetes-sigs/karpenter/blob/v1.0.7/pkg/controllers/metrics/node/controller.go)
- [Eligible-node metric update](https://github.com/kubernetes-sigs/karpenter/blob/v1.0.7/pkg/controllers/disruption/controller.go)
- [Disrupted NodeClaim counter](https://github.com/kubernetes-sigs/karpenter/blob/v1.0.7/pkg/controllers/disruption/orchestration/queue.go)

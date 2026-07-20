# RFC: Migrate the Traefik NLBs from `instance` to `ip` targets

## Status

Draft — proposed migration and validation plan. Not yet executed or validated in the target environment.

## Summary

This RFC proposes an in-place migration of the two existing AWS Network Load Balancers used by these Services from `instance` targets to `ip` targets:

- `traefik-internal/traefik-internal` — internal NLB;
- `traefik-external/traefik-external` — internet-facing NLB with Elastic IP allocations.

Unless stated otherwise, the singular terms *Service*, *NLB*, *listener* and *target group* in this RFC apply independently to each of these migration targets. EIP-specific requirements apply only to `traefik-external`.

The existing NLB, DNS name and listener ports must remain unchanged. The same migration will be delivered for the two Services through two Argo CD PRs:

1. Change the target type to `ip`, enable client-IP preservation and retain the existing NodePorts.
2. After the listeners and IP target groups have been validated, remove the NodePorts and the remaining instance-only Service configuration.

The two-PR sequence is recommended because it keeps the current instance/NodePort path available while AWS Load Balancer Controller (LBC) creates and connects the replacement IP target groups. It reduces the number of dependent changes performed at the same time and provides a clear validation gate before the old NodePort path is removed.

This RFC does not claim that the migration has already been proven in the target environment. It defines expected behavior, the tests used to validate that behavior, and the conditions under which the change may proceed.

This document explains:

- what AWS LBC will change;
- why the change is split into two PRs;
- how the migration will proceed;
- what will be tested;
- how an outage and the AWS transition duration will be measured;
- which signals are required before proceeding or rolling back.

The two reusable probe scripts referenced by this RFC are delivered alongside the document.

## Current state

### Kubernetes Services

```text
Services:
  traefik-internal/traefik-internal
  traefik-external/traefik-external
Type: LoadBalancer
LoadBalancerClass: service.k8s.aws/nlb
Target type: instance (confirm from live state)
GitOps controller: Argo CD
```

Before approval, capture the live ports, NodePorts, health-check NodePort, target-group attributes, listeners and target groups for the migration target.

Known relevant behavior of `traefik-external`:

```yaml
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Local
  healthCheckNodePort: 31828
```

### Known external listener and port mapping

| NLB listener / Service port | Service port name | Current AWS target | Target after migration |
|---:|---|---|---|
| `80` | `http` | node `30421` | Traefik Pod IP, resolved `http` port |
| `443` | `https` | node `30896` | Traefik Pod IP, resolved `https` port |
| `9093` | `tcp` | node `31921` | Traefik Pod IP, resolved `tcp` port |
| `9083` | `tcp-h` | node `32422` | Traefik Pod IP, resolved `tcp-h` port |
| `12012` | `tcp-tls` | node `31325` | Traefik Pod IP, resolved `tcp-tls` port |

The external Service uses named `targetPort` values. AWS LBC resolves these names through the Service endpoints and registers each target as `PodIP:resolved-port`.

The internal Service must be documented in the same mapping format from its live manifest before approval. It is not assumed to have the same ports or NodePorts as the external Service.

For a named target port, the replacement AWS target group can display a nominal `Port=1`. This is expected and is not the actual data-path port. The effective port is the `Target.Port` shown by `describe-target-health`. There is no reason to convert the named ports to numbers during this migration.

### Known external NLB identity that must be preserved

```text
DNS:
  k8s-traefik-traefike-8483922da0-d611ad62084c95a9.elb.us-east-1.amazonaws.com

Scheme:
  internet-facing

Region:
  us-east-1
```

The live NLB ARN, DNS name, listener ARNs and complete subnet mappings must be captured immediately before the change. For `traefik-external`, capture all EIP allocation IDs as well. Values copied from an older manifest or screenshot are not sufficient as final change evidence.

## How the AWS change works

AWS does not allow the target type of an existing target group to be changed. An `instance` target group therefore cannot be edited into an `ip` target group.

AWS LBC must perform the following logical sequence for every Service port:

```text
1. Create a replacement target group with TargetType=ip.
2. Apply the desired target-group attributes.
3. Register Traefik Pod IPs and resolved ports.
4. Update the existing listener to forward to the new target group.
5. Remove the old instance target group.
```

AWS LBC creates one replacement target group per listener/Service port. The known external Service therefore replaces five target groups; the internal count is determined by its live Service ports.

The NLB and listeners are retained. Only the listener default-action target-group ARN changes:

```text
before:
  listener :443 -> instance TG -> node:30896 -> Pod

after:
  listener :443 -> IP TG -> PodIP:resolved-https-port
```

AWS LBC reconciliation is asynchronous. One Argo CD sync is not one atomic AWS operation, and listener cutovers are not guaranteed to happen at the same instant.

### New and existing connections

After a listener starts referencing the new target group:

- new connections use the new IP target group;
- connections opened before the listener update can remain associated with the original target;
- AWS documents that an active TCP/TLS connection can remain on the original target for up to one hour while it continues carrying traffic, or until the idle timeout when it is idle;
- because a target group's target type cannot be changed in place, AWS LBC creates a new `ip` target group and updates the existing listener to reference it; the AWS listener-update behavior described above therefore applies to this migration.

Connections opened before the listener cutover and connections opened during or after the cutover can behave differently. Both must therefore be tested separately.

## Goals

- Keep the existing NLB; for `traefik-external`, also keep its EIPs.
- Migrate every listener to direct Pod IP targets.
- Preserve the original client IP.
- Preserve the current target health and draining attributes.
- Avoid an observable new-connection outage.
- Verify every listener, not only HTTPS on port 443.
- Measure the AWS control-plane transition and client-visible impact.
- Keep a safe instance-mode rollback path until IP mode is proven healthy.

## Non-goals

- Creating a parallel NLB or changing DNS.
- Changing subnets, NLB scheme, NLB name or listener ports; for `traefik-external`, changing its EIPs.
- Recreating or renaming the Kubernetes Service.
- Changing Traefik routes, certificates, Deployments or application protocols.
- Replacing named `targetPort` values with numbers.
- Decoupling target groups into Terraform or manually editing AWS LBC-owned resources.

## Decision and alternatives

### Selected: two in-place PRs

This separates the target-group cutover from NodePort cleanup while preserving the existing NLB identity and addressing.

### Rejected: one PR

One PR is technically possible, but it allows Kubernetes to remove the NodePort path before AWS has completed the IP-target transition.

The expected failure mode is that the old instance path becomes unusable before the replacement IP targets are ready. During that interval, new connections can fail even if connections established before the listener update remain active.

The duration of such an interval is environment-dependent and is deliberately not assumed in this RFC. A one-PR strategy would require a separate non-production validation and its own acceptance criteria; it is not the proposed production procedure.

### Not selected: parallel NLB

A parallel blue/green design would require another NLB, addressing and a DNS or routing cutover. Retaining the existing NLB identity and addressing is a stated requirement.

### Not selected: Terraform target groups and TargetGroupBindings

That design is possible only after explicitly separating ownership of the NLB listeners and target groups from the Service-managed AWS LBC model. Mixing Terraform-owned listener actions with controller-owned resources would create reconciliation conflicts.

## Target-group attributes

The complete desired attribute set must be declared in Git because replacement target groups do not inherit manual settings from the old target groups. The live pre-change inventory must confirm that the following set introduces no unrelated change:

```text
target_health_state.unhealthy.connection_termination.enabled=false
target_health_state.unhealthy.draining_interval_seconds=0
deregistration_delay.timeout_seconds=300
deregistration_delay.connection_termination.enabled=true
preserve_client_ip.enabled=true
```

Resulting annotation:

```yaml
service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: >-
  target_health_state.unhealthy.connection_termination.enabled=false,target_health_state.unhealthy.draining_interval_seconds=0,deregistration_delay.timeout_seconds=300,deregistration_delay.connection_termination.enabled=true,preserve_client_ip.enabled=true
```

The two connection-termination settings control different events:

- `target_health_state.unhealthy.connection_termination.enabled=false` applies when a target becomes unhealthy;
- `deregistration_delay.connection_termination.enabled=true` applies after the 300-second deregistration delay expires.

They can remain together and are supported for IP target groups.

## Migration plan

### Before the maintenance window

The following must be known and recorded:

- exact AWS LBC and Kubernetes versions;
- live Service and EndpointSlices;
- NLB ARN, DNS name, scheme and subnet mappings; include EIP allocations for `traefik-external`;
- every listener ARN/port/TG mapping;
- all old target-group types, target ports, health-check settings, targets and attributes;
- expected Pod count and Availability Zone distribution;
- safe protocol-aware test request and expected response for every listener;
- rollback operator and maintenance window.

The Argo CD Application must be `Synced` and `Healthy`, and the rendered diff must contain no unrelated change.

### PR 1: target migration

PR 1 applies the following target type and complete target-group attribute annotation:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: >-
      target_health_state.unhealthy.connection_termination.enabled=false,target_health_state.unhealthy.draining_interval_seconds=0,deregistration_delay.timeout_seconds=300,deregistration_delay.connection_termination.enabled=true,preserve_client_ip.enabled=true
```

PR 1 deliberately retains:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-target-node-labels: <current value, if present>
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Local
```

All existing NodePorts and each current `healthCheckNodePort` remain present. A target-node-label annotation is ignored by IP targets, but retaining its current Service-specific value makes the PR 1 rollback to instance mode simpler.

### Health-check expectation after PR 1

The replacement IP target groups are expected to use an IP-compatible health check that reaches the Pod target, normally TCP on `traffic-port`, even while `externalTrafficPolicy: Local` is temporarily retained.

This must be verified against the production AWS LBC version and actual Service annotations. Stop before PR 2 if any IP target group incorrectly tries to health-check Pod IPs on a former node `healthCheckNodePort` (`31828` is the known external value).

### PR 1 decision gate

Do not proceed to PR 2 until:

- the NLB ARN, DNS name and subnets are unchanged; the EIPs are also unchanged for `traefik-external`;
- every listener ARN and port is unchanged;
- every listener points to a replacement `TargetType=ip` target group;
- every registered target is the expected Traefik Pod IP and resolved endpoint port;
- all expected targets are healthy in the expected Availability Zones;
- health-check protocol, port and path are correct;
- all five declared target-group attributes have the desired values on every target group;
- new-connection probes pass on every listener and NLB address;
- long-lived probes still exchange data or meet the agreed reconnect SLO;
- the backend sees the original test-client IP;
- AWS LBC has no relevant reconciliation error;
- probes remain clean for at least 10 minutes after all IP targets become healthy.

### PR 2: cleanup

PR 2 removes the instance-only data path:

```yaml
spec:
  allocateLoadBalancerNodePorts: false
  externalTrafficPolicy: Cluster
```

It also removes:

```text
all spec.ports[*].nodePort fields
spec.healthCheckNodePort
service.beta.kubernetes.io/aws-load-balancer-target-node-labels
```

Kubernetes does not automatically release existing NodePorts when only `allocateLoadBalancerNodePorts: false` is set. Every `nodePort` field must be removed from the desired manifest.

PR 2 retains the IP target type and all five declared target-group attributes.

### PR 2 decision gate

After cleanup:

- no application NodePort or `healthCheckNodePort` remains;
- all IP target-group ARNs are unchanged from post-PR 1;
- listener ARNs and listener-to-TG mappings are unchanged;
- PR 2 caused no target-group or listener replacement;
- targets remain healthy;
- all fresh and long-lived probes remain successful for at least 10 minutes;
- the NLB identity remains unchanged; the EIPs also remain unchanged for `traefik-external`.

## Test plan

### Client locations

Use a valid, independent client location for the migration target:

- `traefik-internal`: a client in the VPC or connected network that can reach the internal NLB;
- `traefik-external`: an external or VPN-connected workstation that reaches the public NLB.

An independent client Pod can be used as an additional signal for the internal NLB, but the probe must not run from a Traefik Pod that is itself registered as an IP target. AWS does not support NLB NAT loopback/hairpinning when client-IP preservation is enabled.

### Fresh connections

Use [nlb-continuous-probe.sh](./nlb-continuous-probe.sh) for the reachable HTTPS endpoint:

```bash
./nlb-continuous-probe.sh "https://REAL_HOST/SAFE_PATH" "REAL_HOST" EXPECTED_STATUS 1800 0.1 > new-connections.csv
```

Every attempt creates:

- a new TCP connection;
- a new TLS handshake;
- one HTTP request;
- an explicit connection close.

The CSV records UTC time, monotonic time, curl return code, HTTP status, result, NLB address and DNS/TCP/TLS/total timings.

The probe must start at least five minutes before PR 1 and continue until at least ten minutes after PR 2. Store the output separately for each migration target.

### Long-lived connections

Use [nlb-long-lived-probe.sh](./nlb-long-lived-probe.sh) for port 443, if exposed. Start one connection per resolved NLB address:

```bash
./nlb-long-lived-probe.sh connection-1 NLB_IP REAL_SNI_HOST 1800 2 > long-connection-1.log 2>&1
```

The script opens one TLS socket and sends an HTTP request every two seconds over the same connection. A silent open socket is not sufficient; traffic must continue flowing during both PRs.

Record the connection-open time, every response, listener cutover time, any reset/EOF/timeout and the last successful response.

### Test every listener

A successful HTTPS test does not prove that the remaining listeners work. The following table is the known external listener inventory:

| Listener | Required test | Expected result |
|---:|---|---|
| `80` | HTTP request using real Host/path | agreed status and response marker |
| `443` | fresh TLS/HTTP plus persistent TLS connection | agreed status; no unexpected disconnect |
| `9093` | application-native protocol request | TBD by service owner |
| `9083` | application-native protocol request | TBD by service owner |
| `12012` | TLS handshake plus application request/heartbeat | TBD by service owner |

`nc -z` can be used as a basic diagnostic, but not as final RFC evidence. It proves only that TCP opened, not that the protocol produced a valid response.

Create the equivalent protocol-aware test list for every internal listener from the live Service inventory before approval.

### Client-IP preservation

Send a uniquely identifiable request through each NLB and correlate its UTC timestamp/request identifier with Traefik or backend logs.

Pass condition:

```text
source IP observed by Traefik/backend == original test-client IP
```

The test applies to new connections created after `preserve_client_ip.enabled=true` becomes active.

## What will be checked

| Layer | Check |
|---|---|
| Argo CD | Application health, sync result and exact rendered diff |
| Kubernetes Service | target annotation, NodePorts, traffic policy and unchanged Service identity |
| EndpointSlices | ready Pod IPs and resolved named ports |
| TargetGroupBindings | correct TG references, target type and no reconciliation error |
| NLB | ARN, DNS name, scheme, subnets and security groups unchanged; EIPs unchanged where applicable |
| Listeners | every listener ARN/port unchanged and mapped to the correct new TG |
| Target groups | one IP TG per listener, with correct health checks and attributes |
| Registered targets | correct Pod IP, resolved port, AZ and healthy state |
| New connections | connection success, TLS/HTTP result and latency |
| Existing connections | heartbeat responses without reset/EOF/timeout |
| Client IP | original test-client address visible at the backend |
| AWS control plane | TG creation, listener switch and old-TG cleanup timeline |
| Controller | AWS LBC reconciliation logs |
| Application | Traefik access/error logs and protocol responses |

## Observability

### Primary outage measurement

The client probe is the primary data-plane signal.

Report:

- total attempts, successes and failures;
- last success before a failure window;
- first and last failed attempt;
- first successful attempt after recovery;
- maximum consecutive failures;
- observed failure-window duration;
- maximum gap between probe starts;
- result grouped by NLB address.

If no failure is seen, the result must be bounded by the probe resolution:

```text
No failed connection was observed. The maximum interval between probe starts
was X seconds, so no outage of X seconds or longer was observed. A shorter
interruption between attempts cannot be excluded.
```

Do not state that zero downtime was guaranteed.

### AWS LBC logs

Capture logs from all AWS LBC replicas before, during and after both syncs:

```bash
kubectl -n kube-system logs -f -l app.kubernetes.io/name=aws-load-balancer-controller --all-containers=true --timestamps=true --prefix=true --max-log-requests=10
```

Review Service/model deployment and TargetGroupBinding messages, plus:

```text
Reconciler error
failed to deploy model
AccessDenied
throttling
target registration errors
security-group reconciliation errors
```

AWS LBC logs explain controller intent. They do not prove that traffic worked.

### CloudTrail

CloudTrail provides the AWS API timeline. Capture these ELBv2 management events:

```text
CreateTargetGroup
ModifyTargetGroupAttributes
RegisterTargets
ModifyListener
DeregisterTargets
DeleteTargetGroup
```

Correlate them with the Argo CD sync, first and last listener switch, client failures/recovery and the time all IP targets became healthy.

CloudTrail does not record the exact target-health transition, so `describe-target-health` must also be polled during the migration.

### CloudWatch

Use CloudWatch as supporting evidence:

| Metric | Purpose |
|---|---|
| `ActiveFlowCount` | confirms active connections |
| `NewFlowCount` | confirms fresh traffic |
| `ProcessedBytes` | confirms traffic volume |
| `HealthyHostCount` / `UnHealthyHostCount` | target health per TG |
| `TCP_Client_Reset_Count` | client-generated resets |
| `TCP_Target_Reset_Count` | target-generated resets |
| `TCP_ELB_Reset_Count` | NLB-generated resets |
| `RejectedFlowCount` | rejected NLB flows |
| `SecurityGroupBlockedFlowCount_*_TCP` | NLB security-group blocks |
| `UnhealthyRoutingFlowCount` | fail-open routing where supported |

Important limitations:

- NLB metrics are normally published at 60-second intervals and cannot precisely measure a seconds-long cutover.
- Some metrics are emitted only when non-zero.
- A missing datapoint is not proof of zero errors.
- Reset counters must be correlated with client results; short synthetic connections can create normal reset traffic.
- `TargetConnectionErrorCount` is an Application Load Balancer metric, not a current `AWS/NetworkELB` metric, and must not be used to judge this migration.

### Traefik/application logs

Capture Traefik access and error logs for the same UTC interval to confirm that requests reached Traefik, protocols continued working, the source IP was preserved and no correlated TLS/routing/backend errors occurred.

## Success criteria

The migration passes when:

- the original NLB, subnets and listeners remain; EIPs also remain where applicable;
- one replacement IP target group serves every listener;
- every expected Pod target is healthy on the resolved endpoint port;
- the complete target-group attribute set is correct;
- every listener-specific protocol test passes;
- fresh-connection probes record no failures in the approved measurement window;
- long-lived probes show no unexpected reset, EOF or timeout;
- original client IP preservation is demonstrated;
- no unresolved AWS LBC, Kubernetes or Traefik error correlates with the change;
- PR 2 removes NodePorts without replacing TGs/listeners;
- at least ten clean minutes are observed after each PR gate.

Any isolated client failure must be explained and followed by a new clean observation window before the change is declared successful.

## Rollback

### Failure during PR 1

Do not merge PR 2. Revert the affected Service to target type `instance` through Argo CD.

Because NodePorts, `externalTrafficPolicy: Local` and target-node labels are still present, AWS LBC can create replacement instance target groups using the existing NodePorts.

Rollback is another asynchronous target-group replacement. It is not immediate, so all probes and logging must continue.

### Failure after PR 2

Rollback must be ordered:

1. Restore `allocateLoadBalancerNodePorts: true`, `externalTrafficPolicy: Local`, all original NodePorts/health-check behavior and each Service's target-node labels.
2. Verify that valid NodePorts exist while traffic still uses IP targets.
3. Only then change the target type back to `instance`.

Do not request instance targets before NodePorts exist.

## Main risks

| Risk | Mitigation |
|---|---|
| NodePort removed before IP path is ready | two PRs; retain NodePorts through PR 1 |
| a listener migrates incorrectly | run a separate protocol-aware probe for every listener |
| named target port appears as TG `Port=1` | validate registered `Target.Port`, not only the TG summary |
| IP TG receives a wrong health-check port | verify production LBC behavior and every TG health check |
| replacement TG loses existing attributes | declare and verify the complete attribute annotation |
| Pod SG does not allow direct NLB traffic | validate VPC CNI and backend SG rules before change |
| target Pod performs the probe | use a valid internal/external client or independent non-target Pod |
| one migration target passes while the other fails | require the PR 1 gate to pass for every target before cleanup |
| one NLB address/AZ is broken | run or pin tests against every resolved NLB address |
| CloudWatch hides a short outage | use timestamped client probes as the primary measurement |
| rollback is assumed to be instant | treat rollback as another asynchronous TG replacement |

## Expected behavior and validation hypotheses

The following statements are expectations to be validated during the change. They are not pre-existing test results.

### Expected PR 1 behavior

- AWS LBC creates one replacement target group with `TargetType=ip` for every listener.
- The complete desired attribute set is applied to every replacement target group.
- TargetGroupBindings register the ready Traefik Pod IPs on their resolved endpoint ports.
- Each existing listener is updated to reference its corresponding IP target group.
- Old instance target groups are removed after they are no longer referenced.
- The NLB ARN, DNS name, subnet mappings and listener ARNs remain unchanged; EIPs remain unchanged where applicable.
- Fresh protocol-aware requests continue to succeed throughout the transition.
- Connections opened before listener cutover continue carrying traffic according to the AWS listener-update behavior.
- The exact creation, registration, listener-cutover and cleanup timing is unknown until measured.

### Expected PR 2 behavior

- Kubernetes removes the application NodePorts and health-check NodePort.
- `externalTrafficPolicy` changes to `Cluster` and each instance-only node-label annotation is removed.
- Existing IP target groups and listener mappings do not change.
- No `CreateTargetGroup`, `ModifyListener` or `DeleteTargetGroup` operation is required.
- Fresh and persistent connections continue without interruption.

### Conditions that would disprove the expectations

- a listener points to a missing or incorrect target group;
- a replacement target group registers node addresses or NodePorts instead of Pod IPs and resolved endpoint ports;
- targets do not become healthy or use an incorrect health-check port;
- either NLB, subnet or listener identity changes, or an external EIP changes;
- required target-group attributes are missing;
- any protocol-aware probe fails during a migration or cleanup window;
- a long-lived connection resets, closes unexpectedly or stops returning heartbeats;
- PR 2 creates/replaces AWS target groups or modifies listeners.

All measured timings and results will be added to the change record only after the validation has actually been executed.

## Execution checklist

Complete this checklist for each migration target. PR 2 may proceed only after every PR 1 checklist has passed.

### Before PR 1

- [ ] Complete live Kubernetes and AWS baseline captured.
- [ ] Full Argo CD diff reviewed.
- [ ] All current instance TGs healthy.
- [ ] Fresh-connection probes running.
- [ ] Long-lived connections running where supported.
- [ ] Protocol probes for every listener running.
- [ ] AWS LBC, Traefik and health polling logs running.
- [ ] UTC start time recorded.

### After PR 1

- [ ] NLB/listener identity and applicable EIPs confirmed unchanged.
- [ ] One IP TG per listener confirmed.
- [ ] Pod IP/registered ports confirmed.
- [ ] Health checks and target health confirmed.
- [ ] Five attributes confirmed.
- [ ] Client IP preservation confirmed.
- [ ] No client-probe failure.
- [ ] No unresolved controller/application error.
- [ ] Ten-minute clean hold completed.

### After PR 2

- [ ] All NodePorts and the health-check NodePort removed.
- [ ] Target-node-label annotation removed.
- [ ] IP TG and listener ARNs unchanged from post-PR 1.
- [ ] No target-group/listener replacement caused by cleanup.
- [ ] All probes still pass.
- [ ] Ten-minute clean hold completed.
- [ ] CloudTrail, CloudWatch and application evidence saved.

## Items to complete before approval

- Complete the internal Service listener/port/NodePort inventory.
- Complete live subnet mappings and, where applicable, EIP mappings.
- Confirm production AWS LBC version and rendered IP-target health check.
- Supply the real hostname, safe path and expected HTTP result for each endpoint.
- Define protocol-aware probes and expected responses for every non-HTTP listener.
- Confirm the expected Traefik Pod count and AZ distribution.
- Define where the preserved client IP will be verified.
- Assign change, validation and rollback owners.

## Scripts and references

- [Continuous fresh-connection probe](./nlb-continuous-probe.sh)
- [Long-lived connection probe](./nlb-long-lived-probe.sh)
- [AWS LBC Service annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/)
- [AWS NLB target groups and target types](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html#target-type)
- [AWS NLB listener update and active connections](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/listener-update-rules.html)
- [AWS client-IP preservation considerations](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation)
- [AWS NLB CloudWatch metrics](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-cloudwatch-metrics.html)
- [Kubernetes LoadBalancer NodePort allocation](https://kubernetes.io/docs/concepts/services-networking/service/#disabling-load-balancer-nodeport-allocation)

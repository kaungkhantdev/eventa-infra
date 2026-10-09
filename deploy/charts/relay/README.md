# `relay` — the transactional outbox publisher

Reads `outbox_events` from eventa-api's database and publishes each row to
RabbitMQ with publisher confirms, marking a row published only once the broker
has acknowledged it. It is the bridge between a committed database transaction
and the asynchronous side effect that transaction promised, which is why its
failure mode is so quiet: when the relay stops, orders keep succeeding and no
email leaves the platform.

**This chart implements a specification; it does not make design decisions.**
The sources of truth are
[`devops-infrastructure.md`](../../../../eventa-docs/07-deployment/devops-infrastructure.md)
(§1.2 Helm layout, §3.1 namespaces, §3.2 workloads, §3.3 resources/probes/
disruption/network, §5 config and secrets, §6 scaling, §7 environments, §8
FinOps),
[`devops-ci-cd.md`](../../../../eventa-docs/07-deployment/devops-ci-cd.md)
(§3 image identity, §4.1 promotion, §4.2 rollout strategy, §4.3 sync waves,
§5.1 gated migrations, §5.3 draining) and
[`devops-observability-sre.md`](../../../../eventa-docs/08-maintenance/devops-observability-sre.md)
(§1 signals, §2 outbox lag). Every object comes from the shared
[`_library`](../_library) chart; this chart is values plus `templates/_guard.tpl`,
which adds three refusals of its own.

This is the chart that departs from the documents most, in **three** places, and
all three are the same kind of departure — a document asking for something the
`eventa-relay` image cannot do, or grouping the relay with services whose needs
it does not share:

| | Departure | Why |
| --- | --- | --- |
| 1 | **no `/metrics`**, against observability §1's "all 5 workloads" | the image has no server to scrape |
| 2 | **no probes**, against §3.3's exec/TCP checks and ci-cd §4.3's "every workload defines startup, readiness, liveness" | the image has no health check to call |
| 3 | **no Redis egress**, against §3.3's "api/checkin/worker/relay → Postgres/Redis/RabbitMQ" | the service has no `REDIS_URL` |

All three are under
[What the chart does *not* render](#what-the-chart-does-not-render-and-why).
`Chart.yaml`'s `eventa.io/spec-deviations` annotation carries the same three, and
`eventa-infra/README.md` warning 4 lists the two corrections `eventa-docs` still
needs.

**The replica count is not on that list, and it used to be.**
`devops-infrastructure.md` §3.2 once tabulated the relay at a minimum of 2
replicas with the scaling signal "CPU + outbox lag", and `devops-ci-cd.md` §0
gave it an HPA. Both have been corrected: §3.2 now reads "exactly 1 — a fixed
count, not a minimum" with the signal "None — no HPA", §6 says the relay "does
not scale at all" and that outbox lag "is an alerting signal, not a scaling
signal", and ci-cd §0 reads "exactly 1 replica, no HPA". §3.2 goes further and
documents this chart's render guard. So the singleton below is not a
disagreement with the specification — it *is* the specification, and the guard
is what keeps a values file from leaving both it and the code behind.

## The singleton guard

**The reader does not claim the rows it reads, so a second publisher would send
every event twice. That is why this chart pins one replica and refuses to render
otherwise.** The reason lives in `eventa-relay`, not in a table — which is worth
stating plainly, because a reader who goes to the specification will find it
agreeing (§3.2: "exactly 1 — a fixed count, not a minimum"; §6: the relay "does
not scale at all") and learn nothing from it about *why*.

Verified in the source rather than taken on trust:

| Where | What it says |
| --- | --- |
| `eventa-relay/src/relay/outbox-reader.repository.ts:25` | `fetchBatch` selects pending rows on `isNull(outboxEvents.publishedAt)`, ordered by id. No `FOR UPDATE SKIP LOCKED`. |
| `eventa-relay/src/main.ts:20` | "Scaling this safely needs `FOR UPDATE SKIP LOCKED` in the reader first." |
| `eventa-relay/README.md:22-31` | "Run exactly one replica … Until then the deployment must pin `replicas: 1`." |

Two replicas polling at the same time therefore select the **same** rows, and
both publish them. Consumers dedupe on message id, but only *after* the first
copy has been handled, so two copies delivered concurrently are both handled.
For one registration that is two confirmation emails to the same buyer, and the
buyer notices before the dashboard does.

`eventa-infra/README.md` asks this chart to "make this hard to get wrong, not
just documented". Seven things do that, and every one of them fails the render
rather than emitting a manifest a cluster would accept:

| Attempt | What stops it |
| --- | --- |
| `replicas: 2` in values, a `values-<env>.yaml`, an Argo CD parameter or `--set` | `_library/templates/_validate.tpl` — `fail` with the reason, the evidence and the order the guard may be lifted in |
| Editing the rendered replica count | There is nothing to edit: the Deployment writes **`replicas: 1`** as a literal, not from a value |
| `hpa.enabled: true` | `_validate.tpl` — an autoscaler on a singleton exists only to create the replica that must not exist |
| `updateStrategy.rollingUpdate.maxSurge: 1` | `_validate.tpl` — a surge *is* a second replica, arriving on every deploy |
| `singleton.enabled: false` | **`templates/_guard.tpl`**, this chart's own check. The library cannot tell the workload that must never scale from the four that must, so the value it keys off is not a toggle here |
| `migrationJob.enabled: true` | **`templates/_guard.tpl`** — the Job carries no command, so it runs the relay image's publisher entrypoint: a second publisher that never touches the replica count |
| `replicaCount: 2` | **`templates/_guard.tpl`** — Helm's conventional key, not this library's (`replicas`). It used to render cleanly and change nothing, which is safe but silent; refusing it is cheaper than leaving somebody believing they have two publishers |

**To lift the guard,** in this order: land `FOR UPDATE SKIP LOCKED` in
`eventa-relay/src/relay/outbox-reader.repository.ts`; delete
`templates/_guard.tpl` and the `singleton` block from `values.yaml` in the same
change, so chart and code stop disagreeing at the same commit; only then raise
`replicas` and add the outbox-lag HPA that §3.2 sanctions for that moment and
not before — "the outbox-lag metric that §6 uses for *alerting* can additionally
serve as a scaling signal" once the reader claims rows. Step three without step one
is the double publish.

## What the chart does *not* render, and why

The relay is an application **context**, not a server:
`eventa-relay/src/main.ts:24` calls `NestFactory.createApplicationContext`, and
there is no `listen`, no controller and no port anywhere in `eventa-relay/src`.
Three consequences follow, and all three are deliberate rather than omissions.

**No Service, no Ingress, no container port.** Nothing addresses the relay and
it binds nothing. A declared `containerPort` would be a false claim about the
process in the one place — `kubectl describe pod` — where somebody would read it
and believe it. The NetworkPolicy declares the Ingress type with an empty rule
list, so inbound traffic is denied outright rather than left unmanaged.

**No `/metrics` scrape.** `devops-observability-sre.md` §1 has all five
workloads scraped, and this is the one that cannot be: a scrape annotation would
advertise a target that never answers and read as permanently down. §2
anticipates it, sourcing outbox lag from a "relay gauge / **DB query
exporter**" — and the exporter is the better of the two anyway, because a metric
measured in the database still reports when the relay is gone, which a metric
the relay serves cannot.

**No probes.** §3.3 sends the relay to "exec/TCP checks … plus
broker-connection health" and `devops-ci-cd.md` §4.3 wants it to check "it can
read the outbox and reach RabbitMQ". That is the right probe; eventa-relay does
not ship it. There is no health module and no second binary in the image, and
the two tempting substitutes are each worse than nothing:

- Pointing `exec` at a CLI that is not in the image yet. Readiness would never
  pass, and because a singleton rolls with `maxSurge: 0` the old publisher is
  deleted **before** the new one starts — so every deploy would leave the
  platform with zero publishers until `progressDeadlineSeconds` expires.
- A command that cannot fail, such as `node -e ''`. The kubelet already knows
  the container is running; re-asserting it reports health nothing checked, and
  the relay's real failure — running but not publishing — would read as green.

So the relay is watched from the database instead, which is what both
`eventa-infra/README.md` (warning 2) and `eventa-relay/README.md:74` say to do:

```sql
-- devops-observability-sre.md §2: warn above 30s, page above 120s.
SELECT count(*), min(created_at) AS oldest
  FROM outbox_events WHERE published_at IS NULL;
```

`values.yaml` carries the exact commented-out block to uncomment on the day a
readiness CLI lands — and says to leave liveness off even then, unless the relay
gains a check that can distinguish a wedged event loop from a healthy one. The library validates it: enabling readiness today
fails the render, because the default HTTP handler names a port this workload
does not declare.

## The rest of the shape

| Concern | Value | Source |
| --- | --- | --- |
| Replicas | **1, literal** | the guard above |
| Autoscaling | none | the guard above; §3.2 ("None — no HPA"), §6 ("does not scale at all") and ci-cd §0 ("no HPA") ask for none either |
| CPU / memory | 100m–500m / 256Mi–512Mi | §3.3 |
| PodDisruptionBudget | `minAvailable: 1` | §3.3 |
| Rollout | `RollingUpdate`, `maxSurge: 0`, `maxUnavailable: 1` | ci-cd §4.2, §5.3 |
| Argo CD sync wave | 2 (after the migration Job, before web) | ci-cd §4.3 |
| Termination grace | 60s | ci-cd §5.3 |
| Egress | DNS, Postgres 5432, RabbitMQ 5671 — nothing else | §3.3 |
| Ingress | denied | §3.3 |
| Secrets | `ExternalSecret` from `/eventa/<env>/relay` | §5 |

**`minAvailable: 1` on one replica allows zero voluntary disruptions**, so
`kubectl drain` on the relay's node blocks until an operator deletes the pod by
hand. That is the trade §3.3 chose and it is the right one — a momentary gap in
publishing is recoverable because the outbox row survives (ci-cd §5.3), while
two concurrent publishers are not. It does make the relay the one workload a
node drain cannot fully automate, which is worth knowing before the first
cluster upgrade rather than during it.

**The drain budget is about duplicates, not loss.** On `SIGTERM` the relay
clears its poll timer and closes the app, which closes the AMQP channel and ends
the pg pool (`main.ts:47-50`, `rabbit-publisher.ts:84`,
`database.module.ts:36`). Anything cut off mid-pass is still
`published_at IS NULL` and goes out after the restart
(`rabbit-publisher.ts:70-76`), so 60s exists to avoid `SIGKILL` landing between
a publisher confirm and the `UPDATE` that records it — which is the one way this
service delivers a message twice on its own.

**The egress list is exhaustive, and Redis is not on it.** §3.3 groups the relay
with api/checkin/worker for all three data stores, but `eventa-relay`'s env
schema has no `REDIS_URL` and the service holds no cache, session or idempotency
state (`src/config/env.validation.ts:11-27`). §3.3's own rule is that nothing
undeclared is permitted, and an allow nobody uses is reachability nobody audits.
There is no internet egress either: the relay publishes an event and the
**worker** is what calls the comms providers, which is why the relay is given no
credentials it could leak.

**Migrations are not here.** eventa-api owns every migration; the relay keeps a
typed mirror of the one table it touches and creates nothing
(`src/db/schema/outbox.ts:12`). The gated pre-deploy Job belongs to the api
chart (ci-cd §5.1) — a second Job racing it in wave 1 is exactly the ordering
problem `eventa-infra/README.md` records as warning 3.

**Anti-affinity renders and is currently inert.** The library spreads replicas
across zones (§3.3); with one replica and `maxSurge: 0` there is never a second
pod for the rule to act on. It is left enabled rather than stripped out so that
AZ spreading is not silently lost at the moment the guard is lifted.

**A PR preview cannot scale this to zero.** §8 scales preview environments to
zero when idle through the HPA, and the relay has none — a preview namespace runs
one 100m/256Mi pod for its lifetime. That is also the floor everywhere else,
which is why no environment sizes the relay down.

**And neither can you, from Git.** `replicas: 0` renders as `1` like every other
value, because the literal in the Deployment is the whole point. So a
maintenance window is a cluster-side act, and what it takes differs per
environment — check which one you are in before you start.

| Environment | `syncPolicy` | What happens to `kubectl scale deployment/relay --replicas=0` |
| --- | --- | --- |
| dev, staging, UAT | `automated` with `selfHeal: true` | Argo CD reverts it to the chart's `1` at the next reconciliation. Turn auto-sync off for that Application first, or the window closes itself. |
| **prod** | **no `automated` block at all** | **It persists.** Nothing reverts it. The Application reports OutOfSync until a human syncs. |

**To stop publishing in production:**

```sh
kubectl scale deployment/relay -n eventa-prod --replicas=0
# … window …
# Restore by SYNCING the Application, not by scaling back up: the sync reapplies
# the chart's literal `replicas: 1` and returns the cluster to matching Git.
```

Nothing is lost while it is down: unpublished rows accumulate with
`published_at IS NULL` and drain when the relay returns
(`eventa-relay/README.md:19-20`). The PodDisruptionBudget does not block this —
`minAvailable: 1` is checked by the eviction API, and a scale-down deletes the
pod through the ReplicaSet controller instead.

> **The guard does not reach the cluster, and production has no safety net.**
> Every refusal this chart ships is a *render-time* refusal, and a `kubectl
> scale` never renders the chart. In dev, staging and UAT self-heal is the
> backstop: a hand-scale to 2 is reverted to 1 on its own. **Production, the one
> environment where a duplicate confirmation email reaches a real buyer, is the
> one environment with no backstop** — §1.3 asks for both a gated production
> sync and self-heal, Argo CD cannot give both, and `argocd/README.md` records
> that the gate wins. So `--replicas=2` against `eventa-prod` starts a second
> publisher that reads the same unlocked rows and double-publishes every event,
> for as long as nobody notices; Argo CD will show the Application OutOfSync and
> will not undo it. Scale this Deployment to `0` or to `1`, never to anything
> else, and prefer a sync over a hand-scale for putting it back.

## Files

```
Chart.yaml            depends on ../_library
values.yaml           the baseline: §3.3's figures, the singleton, the egress shape
values-dev.yaml       \
values-staging.yaml    | the four references that genuinely differ per environment:
values-uat.yaml        | pinned image, environment name, secret path, data-subnet CIDRs
values-prod.yaml      /
values.schema.json    the library's values contract, diverging in one documented place
templates/workload.yaml   the guard, then the library's workload
templates/_guard.tpl      the guard
```

`values.yaml` and a `values-<env>.yaml` are both required, and neither renders
alone — deliberately. The baseline has no image tag, because `devops-ci-cd.md`
§1.3 has CI's bot commit the pinned SHA into the **target environment's** values
and a default here would quietly become the version that ships. It has no
data-subnet CIDRs either, because those are a Terraform output per environment
and the library refuses an egress rule with an empty peer list — such a rule
allows every destination rather than none. Helm loads `values.yaml` implicitly,
so an Argo CD `Application` names only the overlay:

```yaml
source:
  path: deploy/charts/relay
  helm:
    valueFiles: [values-prod.yaml]
```

The CIDRs in the overlays are **placeholders** until the Terraform network module
exists; no cloud provider has been chosen, so no real range can be written yet.
Production lists all three per-AZ data subnets on purpose: Postgres fails over to
a standby and RabbitMQ is a three-node cluster (§4), so an allow covering only
the current primary's subnet works until the first failover. Non-production lists
one, because §8 runs those environments on single-node data services.

`values.schema.json` is the library's `values.contract.schema.json` with one
field changed: `ports` accepts the empty list. The contract sets a floor of one
port because every other workload binds one; this one does not.

## Verifying a change

```sh
cd deploy/charts
helm dependency update ./relay          # resolves file://../_library

for env in dev staging uat prod; do
  helm lint ./relay -f relay/values-$env.yaml
  helm template relay ./relay -n eventa-$env -f relay/values-$env.yaml
done
```

Then check the guard still bites — a guard nobody tests is documentation:

```sh
helm template relay ./relay -n eventa-prod -f relay/values-prod.yaml --set replicas=2
helm template relay ./relay -n eventa-prod -f relay/values-prod.yaml --set hpa.enabled=true
helm template relay ./relay -n eventa-prod -f relay/values-prod.yaml --set singleton.enabled=false
helm template relay ./relay -n eventa-prod -f relay/values-prod.yaml \
  --set updateStrategy.rollingUpdate.maxSurge=1
```

All four must exit non-zero.

**`kubectl apply --dry-run=client` is not usable in this repo.** It resolves
every `kind` through API discovery against a live server, so with no cluster it
fails on `dial tcp [::1]:8080: connect: connection refused` before validating
anything — with `--validate=false` as well, since the REST mapping needs
discovery too. Server-side schema validation needs either a cluster or an
offline validator with bundled schemas (`kubeconform`), and neither is available
here yet; adding one is the gap to close, and `devops-ci-cd.md` §2.1 stage 10 —
the IaC scan that already runs over `charts/` — is the pipeline stage it joins.
Until then `helm lint` plus `helm template`
plus a structural pass over the rendered YAML is the check, and
`_library/templates/_validate.tpl` catches at render time most of what the API
server would have caught at apply time.

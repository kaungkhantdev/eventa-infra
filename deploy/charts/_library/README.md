# `_library` — the shared workload chart

A Helm **library chart** (`type: library`). It renders nothing by itself; the five
service charts declare it as a dependency and include its templates. Everything
the five workloads have in common lives here, so a change to a probe or a
disruption budget happens once — which is what `devops-infrastructure.md` §1.2
asks for.

**This chart implements a specification; it does not make design decisions.**
The sources of truth are
[`devops-infrastructure.md`](../../../../eventa-docs/07-deployment/devops-infrastructure.md)
(§1.2 Helm layout, §3.1 namespaces, §3.2 workloads, §3.3 resources/probes/
disruption/network, §5 config and secrets, §6 scaling, §7 environments) and
[`devops-ci-cd.md`](../../../../eventa-docs/07-deployment/devops-ci-cd.md)
(§4.2 rolling vs canary, §4.3 sync waves and rollback, §5.1 gated migrations,
§5.3 outbox and draining). Every non-obvious default in
`templates/_defaults.tpl` cites the section it comes from. There is one place
this chart knowingly contradicts the spec — the relay replica count — and it is
[documented below](#the-relay-singleton-guard).

## Using it

`Chart.yaml`:

```yaml
dependencies:
  - name: eventa-library
    version: 0.1.0
    repository: "file://../_library"
```

`templates/workload.yaml` — the whole chart:

```
{{- include "eventa-library.workload" . }}
```

`values.yaml` then says only what differs from the defaults. Copy
`values.contract.schema.json` to the service chart's root as
`values.schema.json` so `helm lint` and `helm template` check the values:

```sh
cp ../_library/values.contract.schema.json values.schema.json
```

That command is the whole update for `web`, `checkin` and `worker`, whose copies
are byte-identical to this file. **It is not safe for `api` or `relay`**, which
have diverged on purpose: api adds `rollout` and `canary` for its Argo Rollout
(`devops-ci-cd.md` §4.2), and relay relaxes `ports` to `minItems: 0` because it
binds no socket at all. Merge a contract change into those two rather than
overwriting them, and keep a `global.*` key in step across all five — Helm
validates each chart's values against its own schema only, so a key this
contract gains is unvalidated in any chart that did not get it.

It is not named `values.schema.json` *here* because Helm applies a dependency's
schema to that dependency's own values sub-tree. A schema with required
properties at this path would be checked against the library's (empty) coalesced
values and would reject every chart that depends on it.

## What it renders

`eventa-library.workload` emits each of these when its own `enabled` flag is
set, so the five charts differ in values and not in template files.

| Template | Object | Default |
| --- | --- | --- |
| `eventa-library.serviceaccount` | ServiceAccount | on |
| `eventa-library.configmap` | ConfigMap | on when `config.env` is non-empty |
| `eventa-library.externalsecret` | ExternalSecret | off |
| `eventa-library.migrationJob` | Job (Argo `PreSync`, wave 1) | off |
| `eventa-library.deployment` | Deployment | on |
| `eventa-library.service` | Service | on |
| `eventa-library.ingress` | Ingress | off |
| `eventa-library.hpa` | HorizontalPodAutoscaler | off |
| `eventa-library.pdb` | PodDisruptionBudget | on |
| `eventa-library.networkpolicy.defaultDeny` | NetworkPolicy (namespace-wide) | off |
| `eventa-library.networkpolicy` | NetworkPolicy (this workload) | on |

Include them individually when a chart needs something else instead. The api is
canary-deployed with Argo Rollouts (`devops-ci-cd.md` §4.2), so its chart sets
`deployment.enabled: false`, writes its own Rollout, and embeds
**`eventa-library.podTemplate`** — the same probes, security context,
anti-affinity and env wiring the other four get. Point its HPA at the Rollout
with `hpa.scaleTargetRef`.

Helpers worth knowing: `eventa-library.fullname`, `eventa-library.labels`,
`eventa-library.selectorLabels`, `eventa-library.podSelectorLabels`,
`eventa-library.image`, `eventa-library.probes`, `eventa-library.env`,
`eventa-library.envFrom`, `eventa-library.secretName`.

### Two label sets, on purpose

`selectorLabels` is `name` + `instance`: every pod of the release, **including
the migration Job's**. The NetworkPolicy selects on it, because a migration
needs the same database egress as the service whose schema it changes.

`podSelectorLabels` adds `component`, and the Deployment, Service and PDB select
on *that*. The migration Job's pods carry `component: migration`, so they fall
outside it — otherwise the Service would route live requests to a pod running
`migrate` and serving nothing, and the PDB would count it as a replica.

## The values contract

Defaults live in **`templates/_defaults.tpl`**, which is the readable version of
this contract — it is commented per key. `templates/_validate.tpl` enforces the
invariants JSON Schema cannot express. The highlights:

| Key | Notes |
| --- | --- |
| `component` | **Required.** `web`\|`api`\|`checkin`\|`worker`\|`relay`. Part of the workload selector, which is what keeps the `api` and `checkin` pools apart while they run the same image (§3.2). |
| `image.repository` / `image.tag` | **Required.** An immutable git-SHA tag; `latest` and `main` are refused (`devops-ci-cd.md` §3). `image.digest` wins when set. |
| `resources.{requests,limits}.{cpu,memory}` | **Required, all four.** A pod with no requests is BestEffort and a CPU-target HPA has no denominator. Per-workload numbers are in §3.3. |
| `replicas` | Prod minimums in §3.2. Omitted from the Deployment when `hpa.enabled`, so the HPA owns the field and Argo CD self-heal cannot scale the workload back down mid-burst. |
| `probes.{readiness,liveness,startup}` | `type: http\|exec\|tcp` selects the single handler. Defaults: readiness `GET /health/ready`, liveness `GET /health/live`, startup off. |
| `config.env` | Non-secret config → ConfigMap, hashed into the pod template so an edit rolls the pods. A key that reads like a credential is refused; `config.allowSecretLookingKeys` is the escape hatch. |
| `externalSecret` | The only path a secret takes into a pod (§5). Refused if enabled with neither `data` nor `dataFrom`, which would materialise an empty Secret. |
| `hpa` | `cpu.targetAverageUtilization` plus `metrics`, passed through to `autoscaling/v2` verbatim. |
| `pdb` | `minAvailable: 50%`; exactly one of `minAvailable`/`maxUnavailable`. |
| `networkPolicy` | Default-deny plus the declared allows. See below. |
| `singleton` | The relay guard. See below. |
| `argocd.syncWave` | `devops-ci-cd.md` §4.3 fixes the order: **1** migration Job, **2** api/worker/relay, **3** web. No default — each chart states its own. |

### Probes

`devops-infrastructure.md` §3.3 and `devops-ci-cd.md` §4.3:

- **readiness** — `GET /health/ready`, checks DB/Redis/broker, gates traffic and
  rolling updates.
- **liveness** — `GET /health/live`, process-alive only. Pointing it at a path
  containing `ready` is refused: a liveness probe that checks a dependency
  restarts every replica at once the moment that dependency blips, which turns a
  recoverable failover into a cluster-wide crash loop.
- **startup** — on api and worker, to cover a cold NestJS boot before liveness
  starts counting. Default budget 5s × 30.

`api` mounts its routes under a global prefix (`eventa-api/src/main.ts:18` sets
`api/v1`), so its chart sets `/api/v1/health/ready` and `/api/v1/health/live`.
The spec's `/health/*` is the default here because it is what §3.3 states.

§3.3's one sentence about the other two — "workers/relay use exec/TCP checks (no
HTTP server) plus broker-connection health" — does not hold for either of them,
in opposite directions. The library supports all three handler types and takes
no position; both charts state their own and say why.

- **The relay ships no probes at all.** It is an application context with no
  HTTP server (`eventa-relay/src/main.ts:24` calls
  `NestFactory.createApplicationContext`), so the parenthetical is right about
  it — but the prescription is not implementable: TCP has nothing to connect to,
  and the `exec` health command the sentence implies is not in the image. **Do
  not read "the relay uses exec probes" out of this section.**
  [The relay's shape](#per-workload-reference-values) below spells out what
  pointing `exec` at an absent CLI costs, and `relay/values.yaml` argues it at
  length.
- **The worker uses HTTP probes, because the parenthetical is out of date for
  it.** It does serve a small HTTP surface for probes on `PORT` (default 3100 —
  `eventa-worker/src/main.ts:18`, routes in
  `eventa-worker/src/health/health.controller.ts:27,36`), and its liveness
  endpoint already reports "attached to the queue" rather than "the event loop
  still turns", which is the broker-connection health the same sentence asks
  for. Following the letter would give it either an `exec` command that does not
  exist or a TCP check that asserts nothing.

### Network

Default-deny per namespace, then explicit allows (§3.3). Five things shape what
the library renders:

**The data stores are not pods.** Managed Postgres, Redis and RabbitMQ sit in
private data subnets (§2), so their allows are `ipBlock` CIDRs that come from
the Terraform network module per environment:

```yaml
# eventa-staging, which §8 runs on single-node data services — one AZ to allow.
networkPolicy:
  egress:
    postgres: { enabled: true, cidrs: [10.20.1.0/24] }
    rabbitmq: { enabled: true, cidrs: [10.20.1.0/24] }
```

Both lists are the same because §2 puts all three stores in the same per-AZ
data subnets; what keeps the two allows distinct is the per-store port. The
five charts use one placeholder scheme, `10.<env>.<az>.0/24`, and the real
ranges come out of the Terraform network module — so check an existing
`values-<env>.yaml` rather than copying from here.

Set them once for all five charts with
`global.eventa.network.{postgres,redis,rabbitmq}Cidrs` instead if an umbrella
chart owns the values. `global.eventa.network.nodeCidrs` works the same way for
the node ranges of `ingress.fromNodes` below — the one list under that key that
is an app subnet rather than a data subnet.

**An empty rule allows everything.** A NetworkPolicy peer list that renders
empty does not deny — it permits every destination. So enabling a data-store
egress with no CIDR is a **render error**, not a default, and a `fromPods` /
`toPods` entry with no selector is refused for the same reason. The same trap
sits one field over: `ports: []` on a rule does not restrict it to no port, it
matches **every** port, so enabling a peer on a workload that declares no
`values.ports` is refused too.

**The two ingress peers ship placeholder labels, and they have to be replaced.**
A peer here must select *pods*, not just a namespace: §3.1 puts Argo CD,
External Secrets, the ingress controller and the observability agents in one
`platform` namespace, so a namespace-only peer admits all four — which is how
the Argo CD repo-server would get a direct route to `api:3000`, past the CDN →
WAF → load balancer path that §2's table calls the "only ingress path into the
VPC". `_validate.tpl` refuses the namespace-only form outright. But the label
*value* cannot be known yet, because §3.1 names neither the ingress controller
nor the observability stack and neither has been chosen, so `_defaults.tpl`
ships two peers with the right shape and deliberately wrong values:

```yaml
networkPolicy:
  ingress:
    fromIngressController:
      podSelector: { app.kubernetes.io/name: REPLACE-ME-ingress-controller }
    fromMetricsScraper:
      podSelector: { app.kubernetes.io/name: REPLACE-ME-metrics-scraper }
```

No chart in this repo replaces them, so both strings appear verbatim in every
rendered policy and in any Argo CD diff. **Until they are replaced the allow
matches nothing and ingress fails closed** — no pod carries that label. Closed
is the safe direction for a policy and the marker is loud rather than silent,
but the consequence is real wherever the namespace-wide default-deny is on — and
the `api` chart enables it in its baseline, so it is on wherever the api runs.
Inbound traffic to web, api and checkin is dropped, and since
`fromMetricsScraper` is on by default for all five, so is every Prometheus
scrape (`devops-observability-sre.md` §1). Replace both in the chart's values in
the same change that picks an ingress controller and an observability stack.

**Every rendered port is a number, never a named port.** `NetworkPolicyPort`
accepts a name, but nothing in the API guarantees an implementation resolves
it — the CNI would resolve it per destination pod, and no CNI has been chosen
(§3 says only "managed Kubernetes" and nothing in `devops-infrastructure.md`
names a network plugin), which is the same bet the FQDN note below refuses to
make. So inbound names are resolved here instead, against `values.ports`, where
the table is in hand: `ports: [{ port: http }]` on an ingress rule renders as
the number that chart declares for `http`, and a name that is not declared is a
render error rather than a rule that quietly matches no traffic. A name in an
*egress* port list is refused instead, because there the destination is an
`ipBlock` or another workload's pods and this chart does not have their port
table — `web/values.yaml` writes the api's `3000` out for that reason.
Inbound resolution has a second justification worth knowing: the policy selects
on `selectorLabels`, which by design also covers the migration Job's pods, and
the `migrate` container declares no ports at all — so on the api, the one chart
with a Job, `http` would resolve to 3000 for the service's pods and to nothing
for the Job's. Inbound is not even one pod set, which is a second reason not to
leave a name in the manifest for someone else to resolve.

**Kubelet probe traffic is not covered unless you ask for it.** Every rendered
policy declares both policy types, and every *ingress* peer the five charts
declare is a pod selector — so a readiness or liveness probe matches no rule:
the kubelet sends it from the node's own address, and a
`NetworkPolicyPeer` can only be a `podSelector`, a `namespaceSelector` or an
`ipBlock`. A node is neither a pod nor in a namespace, so the API has no peer
that means "the kubelet". `networkPolicy.ingress.fromNodes` is the opt-in allow,
and an `ipBlock` over the private app subnets is the only form it can take —
§2's table places the Kubernetes worker nodes in those subnets, which are *not*
the data subnets the egress allows above use:

```yaml
networkPolicy:
  ingress:
    fromNodes:
      enabled: true
      # Placeholder. The real ranges are the app subnets of §2, per environment,
      # from the same Terraform network module as the data-store CIDRs; empty
      # here falls back to global.eventa.network.nodeCidrs.
      cidrs: [10.40.101.0/24, 10.40.102.0/24]
      ports: []   # empty → the container ports this chart declares, by number
```

It is **off by default** for three reasons. Enabling it widens ingress, which
should be a decision and not a default. Its CIDRs are a per-environment value
from the same Terraform network module as the data-store ranges, so there is
nothing honest to default them to — and `enabled: true` with no CIDR in either
place is a render error, exactly as an empty data-store list is, because an
ingress rule with an empty `from` admits every source rather than none. And most
of the time it is unnecessary: whether a default-deny namespace blocks probes at
all is a property of the CNI rather than of the API, and implementations
commonly do not subject traffic originating on the node to pod policy, which is
why applying a default-deny usually does not break probes.

That last point is the caveat, because it cuts both ways and **no CNI has been
chosen here**. On an implementation that exempts node-sourced traffic,
`fromNodes` buys nothing and only widens the policy. On one that applies pod
policy to it, the HTTP readiness probes that web, api, checkin and worker all
use ([Probes](#probes) above; the relay has none) fail the moment the
default-deny lands, every replica goes NotReady, and the NetworkPolicy is the
last place anyone looks. Turn it on if probes are observed failing under the
default-deny, not pre-emptively — and note that an `exec` probe is not network
traffic and needs no allow at all, which is why a workload that declares no
container port is refused here rather than given a rule.

`egress.external` covers Stripe, PromptPay and the comms providers through NAT.
Plain NetworkPolicy cannot name a destination by hostname — FQDN rules need a
CNI-specific CRD and no CNI has been chosen — so it renders as `0.0.0.0/0` on
the given ports with every private range in `except`. That still keeps the
workload out of the rest of the VPC.

`defaultDeny.enabled` is off by default because the object is namespace-wide.
Enable it in **one** release per namespace — `api` is the natural owner, since
every namespace that runs anything runs it. The object is named per release, so
two charts enabling it is additive and harmless rather than a Helm ownership
conflict between two Argo CD Applications.

### Secrets and config

`devops-infrastructure.md` §5, in one line: config is not secret, secret is
never in Git.

```yaml
config:
  env: { LOG_LEVEL: info }          # → ConfigMap, committed
externalSecret:
  enabled: true
  dataFrom: [{ extract: { key: /eventa/prod/api } }]   # → Secret, reference only
```

`config.env` values are stringified, because a ConfigMap's `data` is
string-to-string and typed parsing is the application's job (each service
validates its own env — see `eventa-api/src/config/env.validation.ts`).

The workload-identity binding that grants least-privilege access to
`/eventa/<env>/*` goes in `serviceAccount.annotations`. Its key is
cloud-specific and §1.1 names the mechanism neutrally ("IRSA/workload-identity"),
so it comes from `values-<env>.yaml` — this chart does not guess at a provider.

Rotation note: `refreshInterval` re-syncs the Secret, but that does not restart
the pods reading it as env vars. §5 describes the behaviour ("rolling-restarts
consumers") without naming a reload controller, so the annotation for one goes
in `podAnnotations` per environment rather than being invented here.

## The relay singleton guard

**The relay's outbox reader takes no row lock, so a second replica publishes
every outbox row twice. That, and not a document, is why this chart pins one
replica.** `devops-infrastructure.md` §3.2 agrees: it tabulates `relay` at
"exactly 1 — a fixed count, not a minimum" with the scaling signal "None — no
HPA", and its closing paragraph names this chart's render-time refusal as the
mechanism that holds the line. Chart and specification say the same thing.

Verified in the source rather than taken from the table:

- `eventa-relay/src/relay/outbox-reader.repository.ts:25` selects pending rows
  on `isNull(outboxEvents.publishedAt)` with no `FOR UPDATE SKIP LOCKED`.
- `eventa-relay/src/main.ts:20` states the precondition directly: "Scaling this
  safely needs `FOR UPDATE SKIP LOCKED` in the reader first."

With two replicas both readers select the same rows and publish every message
twice. Consumers dedupe on message id, but only *after* the first copy
completes, so two concurrent copies are both handled — for a registration, two
confirmation emails to the same buyer.

`eventa-infra/README.md` asks the chart to "make this hard to get wrong, not
just documented", so `singleton.enabled: true` does four things:

1. The Deployment writes **`replicas: 1`** as a literal, not from a value, so no
   values file, Argo CD parameter override or `--set` can raise it.
2. **No HPA is rendered**, and `hpa.enabled: true` fails the render.
3. The rollout is forced to **`maxSurge: 0, maxUnavailable: 1`**
   (`devops-ci-cd.md` §4.2, §5.3). A surge *is* a second replica: under the
   library's default `maxSurge: 1` the new pod would start before the old one
   stopped, giving two concurrent publishers on every deploy. Explicitly asking
   for a surge fails the render rather than being silently corrected.
4. An explicit `replicas:` above 1 fails the render with the file, the line and
   the consequence in the message. An inherited default does not trip it — the
   library defaults `replicas` to 2 for the four scalable workloads, and
   inheriting a default is not somebody asking for a second publisher.

**To lift the guard:** land `FOR UPDATE SKIP LOCKED` in
`eventa-relay/src/relay/outbox-reader.repository.ts`, then remove `singleton`
from the relay chart's values in the same change. Only then raise `replicas`.

What the guard does *not* fix is the failure that actually matters: a relay that
is running but not publishing keeps every probe green while no email leaves the
platform. Alert on **outbox lag**, not pod health —
`devops-observability-sre.md` §2 sets it at warn above 30s, page above 120s.

### One consequence worth knowing before the first node drain

§3.3 specifies `minAvailable: 1` for the relay. With a single replica that
leaves **zero** allowed disruptions, so `kubectl drain` on the relay's node
blocks until an operator deletes the pod by hand. That is the trade the document
chose, and it is a reasonable one — a momentary gap in publishing is recoverable
because the outbox row survives (`devops-ci-cd.md` §5.3), while two concurrent
publishers are not. It is implemented as specified; it is called out here
because it makes the relay the one workload a node drain cannot fully automate.

## Per-workload reference values

Straight from §3.2 and §3.3 — including the relay's row, which §3.2 now states
as "exactly 1 — a fixed count, not a minimum" with the scaling signal "None".

| workload | component | image | replicas (prod) | HPA signal | cpu req/limit | mem req/limit | sync wave |
| --- | --- | --- | --- | --- | --- | --- | --- |
| web | `web` | web | 3 | CPU + RPS | 250m / 1000m | 512Mi / 1Gi | 3 |
| api | `api` | api | 3 | CPU + RPS + p95 latency | 500m / 2000m | 512Mi / 1Gi | 2 |
| checkin | `checkin` | **api** | 2 | CPU + RPS + check-in queue depth | 500m / 2000m | 512Mi / 1Gi | 2 |
| worker | `worker` | worker | 2 | CPU + RabbitMQ queue depth | 250m / 1000m | 512Mi / 1Gi | 2 |
| relay | `relay` | relay | **1, pinned** | **none — no HPA** | 100m / 500m | 256Mi / 512Mi | 2 |

RPS, p95 latency and queue depth go in `hpa.metrics` as `Pods`/`Object`/
`External` entries. The library ships no names for them: those belong to
whichever Prometheus adapter an environment runs, and no document names one, so
a name invented here would produce an HPA that reports `<unknown>` forever.

Below are the keys that define the shape of the guard, copied verbatim from the
real [`../relay/values.yaml`](../relay/values.yaml) with its comments and its
environment-independent remainder (`resources`, `config.env`, `externalSecret`,
`migrationJob`, `networkPolicy`, `argocd.syncWave`) left out. **Read that file
before copying any of this.** Every line here that looks like an omission is
argued there at length, and three of them are the opposite of what a reader
would guess.

```yaml
# deploy/charts/relay/values.yaml — the shape of the guard in use
component: relay
image: { repository: registry.eventa.internal/eventa/relay }   # tag: in values-<env>.yaml
singleton:
  enabled: true
  reason: "fetchBatch takes no row lock, so a second replica selects the same outbox rows and publishes every event twice. Consumers dedupe only after the first copy completes."
  evidence: "eventa-relay/src/relay/outbox-reader.repository.ts:25"
replicas: 1                          # redundant; the Deployment writes the literal 1
hpa: { enabled: false }
service: { enabled: false }          # answers no requests
ports: []                            # binds nothing: it is an application context, not a server
metrics: { enabled: false }          # nothing to scrape — see below
probes:                              # all three off — see below
  readiness: { enabled: false }
  liveness:  { enabled: false }
  startup:   { enabled: false }
pdb: { minAvailable: 1 }
terminationGracePeriodSeconds: 60    # bounds one in-flight pass (ci-cd §5.3)
```

Three of those need the reason, because the plausible-looking alternative is
actively wrong:

- **`ports: []` and `metrics.enabled: false`.** `eventa-relay/src/main.ts:24`
  calls `NestFactory.createApplicationContext` — there is no `listen`, no
  controller and no port anywhere in `eventa-relay/src`. Declaring a
  `containerPort` would be a false claim about the process in the one place
  (`kubectl describe pod`) where somebody would read it and believe it, and a
  scrape annotation would advertise a target that never answers.
  `devops-observability-sre.md` §1 does ask for `/metrics` on all five
  workloads; §2 anticipates this one and sources outbox lag from a "relay gauge
  / DB query exporter" instead, which is the better signal anyway because it
  still reports when the relay is gone.
- **All three probes off.** §3.3 sends the relay to "exec/TCP checks … plus
  broker-connection health" and `devops-ci-cd.md` §4.3 wants it to check "it can
  read the outbox and reach RabbitMQ". That is the right probe and
  `eventa-relay` does not ship it: no health module, no CLI entrypoint, no
  second binary in the image. **Do not point `exec` at a command that is not
  there.** Readiness would never pass, and because a singleton rolls with
  `maxSurge: 0` the old publisher is deleted *before* the new one starts — so
  every deploy would leave the platform with **zero** publishers until
  `progressDeadlineSeconds` expires. A command that cannot fail, such as
  `node -e ''`, is no better: it reports health nothing checked, and the relay's
  real failure, running but not publishing, reads as green.
  `relay/values.yaml` carries the exact commented-out block to uncomment on the
  day a CLI lands, and says to leave liveness off even then.
- **`terminationGracePeriodSeconds: 60`, not longer.** It bounds one in-flight
  pass, not "the longest handler" — the relay has no handlers. Correctness does
  not depend on finishing the pass: a row is marked published only after its
  confirm returns, so anything cut off is still `published_at IS NULL` and goes
  out next pass. The budget exists so `SIGKILL` does not land between a
  publisher confirm and the `UPDATE` that records it, which is the one way this
  service delivers a message twice on its own.

## Verifying a change

```sh
helm lint deploy/charts/_library

# Render through a consumer: a library chart cannot be templated directly, and
# the five that depend on it are the consumers. `charts/` is git-ignored, so
# re-resolve the dependency after editing anything under templates/ — the
# consumer renders the packaged copy, not these files.
helm dependency update deploy/charts/relay
helm template relay deploy/charts/relay -f deploy/charts/relay/values-prod.yaml -n eventa-prod
```

Pair every chart with exactly one `values-<env>.yaml` and the matching
namespace. None of the five renders bare today, and that is the right
direction rather than a gap: web, checkin, relay and worker fail their own
`values.schema.json` on the image reference, which belongs to the environment
(`devops-ci-cd.md` §4.1 makes promotion "a PR that bumps the target env's image
digest", so a tag sitting in a baseline would be a version nobody promoted),
and the api fails its own chart's validation because its canary gate has no
Prometheus address until an environment supplies one. A bare render that
succeeded would be a manifest no environment would ever apply.

`kubectl apply --dry-run=client` is **not** usable here: it resolves every
`kind` through API discovery against a live server, so with no cluster it fails
on connection refused before it validates anything. Server-side schema checks
need either a cluster or an offline validator with bundled schemas
(`kubeconform`), neither of which is available in this repo yet. Until then,
`helm template` plus a structural pass over the rendered YAML is the check —
and `_validate.tpl` catches at render time most of what the API server would
have caught at apply time.

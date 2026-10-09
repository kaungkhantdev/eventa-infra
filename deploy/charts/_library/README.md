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

The relay is an application context with no HTTP server at all
(`eventa-relay/src/main.ts`), so it uses `exec` probes. **The worker is not:** it
does serve a small HTTP surface for probes on `PORT` (default 3100 —
`eventa-worker/src/main.ts:18`, routes in `eventa-worker/src/health/health.controller.ts`),
and its liveness endpoint already reports "attached to the queue" rather than
"the event loop still turns". §3.3's "workers/relay use exec/TCP checks (no HTTP
server)" is therefore accurate for the relay and out of date for the worker. The
library supports all three handler types and takes no position; the worker chart
should use the endpoints that exist.

### Network

Default-deny per namespace, then explicit allows (§3.3). Two things shape it:

**The data stores are not pods.** Managed Postgres, Redis and RabbitMQ sit in
private data subnets (§2), so their allows are `ipBlock` CIDRs that come from
the Terraform network module per environment:

```yaml
networkPolicy:
  egress:
    postgres: { enabled: true, cidrs: [10.20.1.0/24] }
    rabbitmq: { enabled: true, cidrs: [10.20.5.0/24] }
```

Set them once for all five charts with
`global.eventa.network.{postgres,redis,rabbitmq}Cidrs` instead if an umbrella
chart owns the values.

**An empty rule allows everything.** A NetworkPolicy peer list that renders
empty does not deny — it permits every destination. So enabling a data-store
egress with no CIDR is a **render error**, not a default, and a `fromPods` /
`toPods` entry with no selector is refused for the same reason.

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

**`devops-infrastructure.md` §3.2 tabulates `relay` at a minimum of 2 replicas.
That entry is a defect in the document, and this chart deliberately does not
implement it.**

The relay's outbox reader takes no row lock. Verified in the source:

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

From §3.2 and §3.3, with the relay's replica count per the guard above.

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

```yaml
# relay/values.yaml — the shape of the guard in use
component: relay
image: { repository: registry.eventa.internal/eventa/relay, tag: sha-9f3c1a2 }
singleton:
  enabled: true
  reason: "The outbox reader takes no row lock, so a second replica double-publishes every event."
  evidence: "eventa-relay/src/relay/outbox-reader.repository.ts:25"
service: { enabled: false }          # answers no requests
ports: [{ name: metrics, containerPort: 3200 }]
metrics: { port: metrics }
probes:
  readiness: { type: exec, exec: { command: ["node", "dist/health/readiness-cli.js"] } }
  liveness:  { type: exec, exec: { command: ["node", "dist/health/liveness-cli.js"] } }
pdb: { minAvailable: 1 }
terminationGracePeriodSeconds: 90    # ≥ the longest handler (ci-cd §5.3)
```

## Verifying a change

```sh
helm lint deploy/charts/_library

# Render through a consumer. A library chart cannot be templated directly;
# use a throwaway chart outside this repo that depends on it.
cd /tmp/render-test/relay && helm dependency update . && helm template relay . -n eventa-prod
```

`kubectl apply --dry-run=client` is **not** usable here: it resolves every
`kind` through API discovery against a live server, so with no cluster it fails
on connection refused before it validates anything. Server-side schema checks
need either a cluster or an offline validator with bundled schemas
(`kubeconform`), neither of which is available in this repo yet. Until then,
`helm template` plus a structural pass over the rendered YAML is the check —
and `_validate.tpl` catches at render time most of what the API server would
have caught at apply time.

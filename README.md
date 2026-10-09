# eventa-infra

Helm charts and Argo CD for running [Eventa](../eventa-docs).

> **Status: the Kubernetes layer is built.** Five Helm charts over a shared
> library chart, plus the Argo CD App-of-Apps that deploys them into
> `eventa-dev`, `eventa-staging`, `eventa-uat` and `eventa-prod`.
>
> **`terraform/` is not built.** No cloud provider has been chosen, and
> `devops-infrastructure.md` §1.1 deliberately names none ("IRSA/workload-identity"
> covers both AWS and GCP), so every address that a Terraform module would
> output — data-subnet CIDRs, bucket regions, the registry host, the
> workload-identity annotation — is a marked placeholder in a
> `values-<env>.yaml`. Each one says which module owns it. Nothing deploys until
> they are real.
>
> Two placeholders are **not** Terraform outputs and are easy to miss for that
> reason: the `podSelector` values that the NetworkPolicy ingress allows use to
> identify the ingress controller and the metrics scraper. §3.1 says only that
> both run in `platform` and names neither product, so the library ships
> `app.kubernetes.io/name: REPLACE-ME-ingress-controller` and
> `REPLACE-ME-metrics-scraper` — the right shape with a deliberately wrong
> value. They fail **closed**: no pod carries that label, so until they are
> replaced the allow matches nothing and inbound traffic to the workload stops.
> The marker appears verbatim in the rendered object and in an Argo CD diff.
>
> **Known gaps.** Two are open, and one was a live defect that is now fixed —
> recorded because it is the failure mode this repo is most likely to recreate:
>
> 1. **`values-uat.yaml` is missing for `checkin` and `worker`**, so two of
>    UAT's five Argo CD Applications cannot sync at all. The
>    `argocd/environments/uat/*.yaml` Applications already reference the file,
>    and nothing overrides it — no Application in this repo carries
>    `helm.parameters`. [argocd/README.md](argocd/README.md) lists what each
>    file has to contain, and why the CIDR scheme has to be settled first:
>    `api`, `checkin`, `worker` and `relay` currently name three different
>    ranges for the same production Postgres, so the UAT files must not add a
>    fourth.
> 2. **PR preview environments are not implemented.** §3.1's `preview-<pr>`
>    namespace and ci-cd §1.1's `ApplicationSet` are absent on purpose; the
>    three blockers are written out in
>    [argocd/projects/eventa-preview.yaml](argocd/projects/eventa-preview.yaml).
> 3. **Fixed: the NetworkPolicies used to break the `web` → `api` path.** A
>    default-deny namespace needs the source's egress *and* the destination's
>    ingress, and no chart in this repo set
>    `networkPolicy.ingress.fromPods` at all — so `web` could send and the api
>    would not receive, in every environment, while the Ingress, Service,
>    Rollout and pods all reported healthy. `api/values.yaml` now carries the
>    ingress half, selecting `app.kubernetes.io/name: web` and
>    `component: web` on 3000, in the baseline so every overlay inherits it.
>    **An in-cluster caller added later needs the same pair of allows**, and
>    §3.3's "no pod-to-pod that isn't declared" is the rule that makes a
>    forgotten declaration silent rather than refused.
>
> Local development still runs the whole platform from `docker compose` in
> `eventa-api` — see [below](#local-development).

## The design already exists — read it first

Do not design the infrastructure here. It is specified, and these are the source
of truth:

| Document | Covers |
| --- | --- |
| [devops-infrastructure.md](../eventa-docs/07-deployment/devops-infrastructure.md) | **Start here.** Terraform layout, Helm charts, the Kubernetes topology, managed Postgres/Redis/RabbitMQ, secrets, scaling, FinOps |
| [devops-ci-cd.md](../eventa-docs/07-deployment/devops-ci-cd.md) | Pipelines, environments, GitOps promotion, gated DB migrations, rollback |
| [devops-architecture.md](../eventa-docs/07-deployment/devops-architecture.md) | The DevOps overview and the deployable inventory |
| [software-architecture.md §8](../eventa-docs/04-architecture/software-architecture.md) | The deployment view the above implement |
| [devops-observability-sre.md](../eventa-docs/08-maintenance/devops-observability-sre.md) | The signals every service must emit |

There are **six** places where these charts do not do what one of those
documents says — four because the document is wrong, two because it asks for
something the service cannot yet do. All six are listed under **warning 4**,
with the five upstream corrections they need. Nothing else in these charts
departs from the documents.

## Layout

```
eventa-infra/
├── deploy/charts/
│   ├── _library/       shared templates: probes, HPA, PDB, NetworkPolicy,
│   │                   ExternalSecret, the Deployment skeleton, the migration Job
│   ├── web/  api/  worker/  relay/
│   └── checkin/        the api image again, own Deployment + scaling policy
└── argocd/             App-of-Apps; environments promote by moving a pinned SHA tag
    ├── root.yaml       applied by hand at bootstrap, with projects/platform.yaml
    ├── apps/           the root Application per environment, plus projects.yaml
    ├── projects/       one AppProject per namespace in §3.1
    └── environments/   one Application per service per environment (5 × 4)
```

`terraform/` will sit beside these, laid out per `devops-infrastructure.md` §1.1
(`modules/` pinned by git ref, `envs/{dev,staging,uat,prod}`, a single `global/`
state).

Nothing in `argocd/` carries an image reference. The deployed version of a
service is the immutable SHA tag in
`deploy/charts/<service>/values-<env>.yaml` (§1.2), so a promotion is a one-line
edit to a values file and a production sync is the one step that waits for a
human. [argocd/README.md](argocd/README.md) has the full model.

## What has to be deployed

Five workloads. All of them are required — the platform is not functional with a
subset. Figures are `devops-infrastructure.md` §3.2 and §3.3.

| Workload | Image | Min replicas (prod) | Scaling signal | CPU req/limit | Mem req/limit |
| --- | --- | --- | --- | --- | --- |
| `web` | web | 3 | CPU + RPS | 250m / 1000m | 512Mi / 1Gi |
| `api` | api | 3 | CPU + RPS + p95 latency | 500m / 2000m | 512Mi / 1Gi |
| `checkin` | api | 2 | CPU + RPS + check-in queue depth | 500m / 2000m | 512Mi / 1Gi |
| `worker` | worker | 2 | CPU + RabbitMQ queue depth | 250m / 1000m | 512Mi / 1Gi |
| `relay` | relay | **exactly 1** | none; no HPA | 100m / 500m | 256Mi / 512Mi |

`checkin` runs the **same image as `api`** in its own Deployment and HPA, so a
door-scanning surge at a live event cannot starve checkout traffic. `api` is the
only one deployed progressively (Argo Rollouts canary, `devops-ci-cd.md` §4.2).

Plus managed **PostgreSQL** (primary + replica), **RabbitMQ** (clustered),
**Redis**, and object storage — all Terraform, none of it built.

## Four things that will bite whoever works on this

**1. `relay` must be pinned to one replica.** Its reader takes no row lock, so a
second instance selects the same outbox rows and publishes every message twice —
and consumers only dedupe *after* the first copy completes, so two concurrent
copies are both handled. For a registration that means two confirmation emails to
the same buyer. The chart now enforces this rather than asking: `replicas: 1` is
a literal, there is no HPA, the rollout is stop-then-start so two publishers
never overlap, and the chart **fails to render** if anyone raises the count. Try
it:

```sh
helm template relay deploy/charts/relay -n eventa-prod \
  -f deploy/charts/relay/values-prod.yaml --set replicas=2
# Error: execution error at (relay/templates/workload.yaml:17:4):
# SINGLETON GUARD — refusing to render the `relay` chart.
```

The same guard trips on `hpa.enabled=true`, on
`updateStrategy.rollingUpdate.maxSurge=1` (a surge *is* a second replica) and on
`singleton.enabled=false`. All four are verified failing. There is also no Argo
CD route to it: no Application in `argocd/` carries a `helm.parameters` block, so
the replica count cannot be overridden from outside the values files the chart
validates.

**The guard stops at the cluster boundary, and production has no net past it.**
Every one of those four refusals happens at *render* time, and `kubectl scale`
never renders the chart. In `eventa-dev`, `eventa-staging` and `eventa-uat`
Argo CD self-heal is the backstop — a hand-scaled relay goes back to the chart's
literal `1` on its own. **`eventa-prod` has no `automated` block at all**, so
nothing reverts anything there: §1.3 asks for both a gated production sync and
self-heal, Argo CD cannot give both, and
[argocd/README.md](argocd/README.md) records that the gate wins. A
`kubectl scale deployment/relay -n eventa-prod --replicas=2` therefore starts a
second publisher and duplicates every event for as long as nobody reads the
OutOfSync status. Scale it to `0` or `1`, never above;
[deploy/charts/relay/README.md](deploy/charts/relay/README.md) has the
maintenance-window procedure.

**2. A liveness probe will not catch the failure that matters.** If the relay is
running but not publishing, every probe is green and no email leaves the platform
— silently, while orders keep succeeding. The signal to alert on is **outbox
lag**:

```sql
SELECT count(*) FROM outbox_events WHERE published_at IS NULL;
```

Alert on that growing, not on pod health. Same for the worker: alert on DLQ
**rate**, not depth — depth only ever climbs, so everyone learns to ignore it.

**3. Migrations are gated and one-way.** `eventa-api` owns every migration, and
`eventa-worker` and `eventa-relay` keep typed mirrors of the tables they touch.
A migration that adds an enum value must ship before, or with, the services whose
mirrors use it — a mirror that lags fails on write, not on read, so it fails in
production rather than in CI. See
[devops-ci-cd.md](../eventa-docs/07-deployment/devops-ci-cd.md) for the gate.

Argo CD will not catch this for you. The gate it *does* enforce is the api's
pre-deploy migration Job, a `PreSync` hook with `backoffLimit: 0`, so no api pod
starts against an un-migrated schema. Ordering `worker` and `relay` against that
Job is a release-sequencing problem, because §1.3 makes each service its own
Application and sync waves only order resources *within* one —
[argocd/README.md](argocd/README.md) explains why annotating the Applications
would make it worse.

**4. `devops-infrastructure.md` §3.2 is wrong about the relay, and the charts
refuse to follow it.** This one is new and is not recorded in any document in
`eventa-docs`.

§3.2 tabulates `relay` at a **minimum of 2 replicas**, and §6 adds that "`relay`
scales with outbox lag". Both describe the right design for a reader that claims
rows. That reader does not exist:

| Evidence | What it says |
| --- | --- |
| [`eventa-relay/src/relay/outbox-reader.repository.ts:25`](../eventa-relay/src/relay/outbox-reader.repository.ts) | `fetchBatch` selects pending rows on `isNull(outboxEvents.publishedAt)`. There is no `FOR UPDATE SKIP LOCKED`, so two readers polling at the same time return the **same rows**. |
| [`eventa-relay/src/main.ts:20`](../eventa-relay/src/main.ts) | "Scaling this safely needs `FOR UPDATE SKIP LOCKED` in the reader first." |

Following §3.2 would double-publish every outbox message: both replicas select
the row, both publish it, both mark it published. Consumers dedupe on message id
but only *after* the first copy has been handled, so two copies delivered
concurrently are both handled — one registration, two confirmation emails.

So the charts pin one replica, ship no HPA for the relay, and fail to render if
anyone raises the count (warning 1 shows the error). **The chart is right and the
document is wrong**, which is the opposite of the rule at the top of this file.

It is not, however, the only place the charts and the documents disagree. The
full list is below, because "the charts implement the spec except here" was the
claim this file used to make and it was not true.

**Before the guard can be lifted, in this order:**

1. Land `FOR UPDATE SKIP LOCKED` in
   `eventa-relay/src/relay/outbox-reader.repository.ts` so concurrent readers
   claim disjoint rows, and remove the warning at `eventa-relay/src/main.ts:15-20`.
2. Delete `deploy/charts/relay/templates/_guard.tpl` and the `singleton` block
   from `deploy/charts/relay/values.yaml` in the same change, so the chart and the
   code stop disagreeing at the same commit.
3. Only then raise `replicas` and add the outbox-lag HPA §6 asks for, keeping the
   PodDisruptionBudget at or above one publisher.

Step 3 without step 1 is the double-publish.

### Every place the charts do not do what a document says

Six, verified by rendering each chart rather than by reading its comments. Four
of them (1, 2, 5, 6) are cases of the document being **wrong** — a figure that
contradicts the code, or a grouping that puts the relay with services whose
needs it does not share. Two (3, 4) are cases of a document asking for something
`eventa-relay` **cannot yet do**; those close when the service gains the
feature, not when the document is edited. None of them is a free choice, and
each is argued in the chart that makes it.

| # | Deviation | What the document says | Why the chart differs |
| --- | --- | --- | --- |
| 1 | **relay runs exactly 1 replica** | `devops-infrastructure.md` §3.2: minimum 2 | The reader takes no row lock. The two source lines above. **The document is wrong.** |
| 2 | **relay ships no HPA at all** | §3.2 gives it the signal "CPU + outbox lag"; §6 lists "queue depth (worker/relay)" and "`relay` scales with outbox lag"; **`devops-ci-cd.md` §0** tabulates it as "1 Deployment + HPA (singleton-safe)" | Same defect as 1, in four more entries (§3.2's signal column, §6's Pods row, §6's Consumers row, ci-cd §0's relay row). Until the reader claims rows an autoscaler's only job is to create the replica that must not exist. Outbox lag still *is* the signal — it wakes a human (observability §2). **The documents are wrong.** |
| 3 | **relay serves no `/metrics`** | `devops-observability-sre.md` §1: "all 5 workloads via `/metrics`" | `eventa-relay/src/main.ts:24` creates an application *context* — no `listen`, no controller, no port, so there is nothing to scrape. §2 anticipates this and sources outbox lag from a "relay gauge / **DB query exporter**", which is the better signal anyway because it still reports when the relay is gone. |
| 4 | **relay ships no probes** | §3.3: "Workers/relay use exec/TCP checks … plus broker-connection health"; `devops-ci-cd.md` §4.3: "every workload defines `startup`, `readiness`, `liveness`" | That is the right probe and `eventa-relay` does not have it: no health module, no CLI entrypoint, no second binary. TCP has nothing to connect to. With `maxSurge: 0`, an `exec` probe pointed at an absent command would leave **zero** publishers on every deploy. |
| 5 | **relay has no Redis egress** | §3.3 groups "api/checkin/worker/relay → Postgres/Redis/RabbitMQ" | `eventa-relay`'s env schema has no `REDIS_URL` and the service holds no cache, session or idempotency state (`src/config/env.validation.ts:11-27`). §3.3's own rule is that nothing undeclared is permitted. |
| 6 | **worker uses HTTP probes, not exec/TCP** | the same §3.3 sentence's "(no HTTP server)" | Out of date for the worker: `eventa-worker/src/main.ts:18` calls `app.listen(port)` and `src/health/health.controller.ts:27,36` serves `/health/live` and `/health/ready`, with liveness reporting "attached to the queue" — which is the broker-connection health the same sentence asks for. **The parenthetical is wrong.** |

Two further places where the *documents disagree with each other* and the charts
follow the more specific one, which is a reading rather than a deviation:

- **`web` has no startup probe.** §3.3 puts a startup probe "on api/worker";
  ci-cd §4.3 says every workload defines one. The charts follow §3.3, and web is
  a Node SSR server with no cold NestJS boot to cover.
- **UAT auto-syncs although §7 calls it "gated".** ci-cd §4.1 gates UAT on an
  approval of the *promotion*; §1.3 and §4.1 reserve a gated *sync* for
  production. [argocd/README.md](argocd/README.md) works this through.

### `eventa-docs` needs five corrections and this repo cannot make them

`eventa-docs` is read-only from here, so every entry below is still uncorrected
upstream. Someone with write access should amend all five — correcting only
§3.2 and §6 would leave `devops-ci-cd.md` §0 still specifying an HPA for the
relay, which is the entry a reader is most likely to hit first, since §0 is the
inventory table at the top of that document.

| Document and entry | Should say |
| --- | --- |
| `devops-infrastructure.md` §3.2, relay row | **exactly 1** replica, scaling signal **none**, until `eventa-relay`'s reader takes a row lock. Reference `outbox-reader.repository.ts:25` and `main.ts:20`. |
| `devops-infrastructure.md` §6, the Pods and Consumers rows | Drop `relay` from "queue depth (worker/relay)" and strike "`relay` scales with outbox lag". Outbox lag stays an **alerting** signal, not a scaling one. |
| **`devops-ci-cd.md` §0**, relay row | "1 Deployment, **no HPA**" — not "1 Deployment + HPA (singleton-safe)". A singleton-safe HPA is not a thing that exists here. |
| `devops-observability-sre.md` §1, Metrics row | "all 5 workloads via `/metrics`" → four; the relay is measured by the DB query exporter §2 already names. |
| `devops-infrastructure.md` §3.3, NetworkPolicy allows and probes bullet | Drop `relay` from the Redis grouping, and drop "(no HTTP server)" from the workers half of the probes sentence. |

Until those land, the next reader of the specification will believe the tables
and reopen all of this. The two charts that deviate carry their own entries in a
`eventa.io/spec-deviations` annotation — `deploy/charts/relay/Chart.yaml` has
items 1–5 plus this correction list, and `deploy/charts/worker/Chart.yaml` has
item 6 — so a deviation travels with the chart that makes it and not only with
this file.

## Working on the charts locally

There is no cluster, and you should not try to reach one. `helm lint` and
`helm template` are the gate.

```sh
cd /Users/rio/Data/rio/eventa/eventa-infra

# Resolve the file://../_library dependency. The vendored tarball under
# charts/ is gitignored; Chart.lock pins it. Argo CD does this on every sync.
for c in _library web api checkin worker relay; do helm dependency build deploy/charts/$c; done

# Lint and render every chart against every environment overlay it has.
for c in web api checkin worker relay; do
  for e in dev staging uat prod; do
    f=deploy/charts/$c/values-$e.yaml
    [ -f "$f" ] || { echo "SKIP $c/$e (no overlay)"; continue; }
    helm lint     deploy/charts/$c -f "$f" -n "eventa-$e" >/dev/null &&
    helm template "$c" deploy/charts/$c -f "$f" -n "eventa-$e" >/dev/null &&
      echo "OK   $c/$e" || echo "FAIL $c/$e"
  done
done
```

`checkin` and `worker` have no `values-uat.yaml` yet, so expect two `SKIP`
lines — that is the gap [argocd/README.md](argocd/README.md) tracks. Everything
else should print `OK`; 18 of the 20 service/environment pairs render today.

**No chart renders without an environment overlay, and that is deliberate.** The
baseline `values.yaml` of each chart is the production sizing from §3.3 with
nothing environment-specific in it; the overlay supplies the image tag, the
secret path, the hostnames and the data-subnet CIDRs. Rendering without one
fails, rather than quietly deploying a chart that has no secrets and an
unpullable image.

They do not all fail on the same thing, and the difference matters when you are
reading an error:

| Chart | `helm template <chart> deploy/charts/<chart>` fails on |
| --- | --- |
| `web`, `checkin`, `worker`, `relay` | the values schema, at `/image`: no usable `tag` and no `digest`. (`web`, `checkin` and `relay` have no `tag` key at all; `worker`'s is present and empty, so its message is a `minLength` failure rather than a missing property.) |
| `api` | its **templates** — `canary.analysis` has a Prometheus gate with no `prometheusAddress` |

The api's baseline does not reach the image check, because `canary.analysis` is
validated first; the overlay is where the Prometheus address lives
(observability §1 puts the metric sink in `platform`, per environment). So a
missing overlay is always caught, but "the image tag is missing" is not a
reliable thing to expect in the message.

Use the release name shown above — the **service** name, not a per-environment
one, because `web` reaches the api at `http://api/api/v1`.

**`kubectl apply --dry-run=client` does not work here.** It resolves every `kind`
through API discovery against a live API server, so with no cluster it fails on
`connection refused` before validating anything, and `--validate=false` fails the
same way on `/api`. Offline schema validation needs `kubeconform`, which is not
installed. Each chart's README records this too.

## Local development

Local development runs the whole platform from
[`eventa-api/docker-compose.yml`](../eventa-api/docker-compose.yml) (Postgres,
RabbitMQ, Mailpit) plus the four services started by hand — see
[how-services-connect.md](../eventa-docs/04-architecture/how-services-connect.md).
Nothing in this repo is involved; the charts and the Argo CD manifests describe a
cluster that does not exist yet.

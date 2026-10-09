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
> Also missing, and tracked in [argocd/README.md](argocd/README.md): PR preview
> environments, and `values-uat.yaml` for three of the five charts.
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

One entry in those documents is a defect and the charts deliberately contradict
it. See **warning 4**.

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

The same guard trips on `hpa.enabled=true` and on `singleton.enabled=false`.
There is also no Argo CD route to it: no Application in `argocd/` carries a
`helm.parameters` block, so the replica count cannot be overridden from outside
the values files the chart validates.

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
document is wrong**, which is the opposite of the rule at the top of this file,
and it is the only place that is true.

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

**`eventa-docs` needs a correction and this repo cannot make it.** `eventa-docs`
is read-only from here, so §3.2's relay row and §6's "relay scales with outbox
lag" are still uncorrected upstream. Someone with write access should amend both
to say *exactly 1 until the reader takes a row lock*, and reference the two
source lines above — otherwise the next reader of the specification will believe
the table and reopen this.

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

Three charts have no `values-uat.yaml` yet, so expect three `SKIP` lines — those
are the gap [argocd/README.md](argocd/README.md) tracks.

**A chart will not render without an environment overlay, and that is
deliberate.** The baseline `values.yaml` of each chart is the production sizing
from §3.3 with nothing environment-specific in it; the overlay supplies the
image tag, the secret path, the hostnames and the data-subnet CIDRs. Rendering
without one fails on whichever of those is missing first, rather than quietly
deploying a chart that has no secrets and an unpullable image. Use the release
name shown above — the **service** name, not a per-environment one, because
`web` reaches the api at `http://api/api/v1`.

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

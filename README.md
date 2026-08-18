# eventa-infra

Terraform, Helm and Argo CD for running [Eventa](../eventa-docs).

> **Status: empty.** Nothing has been built here yet. The design is complete and
> lives in `eventa-docs`; this repo is where it gets implemented. Until then,
> everything runs locally from `docker compose` in `eventa-api`.

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

## Intended layout

Per `devops-infrastructure.md`:

```
eventa-infra/
├── terraform/          # network, managed Postgres/Redis/RabbitMQ, object storage, DNS
│   └── modules/        # pinned by git ref, so a prod apply is reproducible
├── deploy/charts/
│   ├── _library/       # shared templates: probes, HPA, PDB, NetworkPolicy, ExternalSecret
│   ├── web/  api/  worker/  relay/
│   └── checkin/        # the api image again, own Deployment + scaling policy
└── argocd/             # App-of-Apps; environments promote by moving a pinned SHA tag
```

## What has to be deployed

Five workloads. All of them are required — the platform is not functional with a
subset.

| Workload | Image | Replicas | Notes |
| --- | --- | --- | --- |
| `web` | eventa-web | ≥2, autoscale | Static/SSR behind the CDN |
| `api` | eventa-api | ≥2, autoscale | HTTP only |
| `relay` | eventa-relay | **exactly 1** | See below — this one is not negotiable yet |
| `worker` | eventa-worker | ≥2 | Competing consumers |
| `checkin` | eventa-api | own HPA | Same image, isolated pool for door-scan spikes |

Plus managed **PostgreSQL** (primary + replica), **RabbitMQ** (clustered),
**Redis**, and object storage.

## Three things that will bite whoever builds this

**1. `relay` must be pinned to one replica.** Its reader takes no row lock, so a
second instance selects the same outbox rows and publishes every message twice —
and consumers only dedupe *after* the first copy completes, so two concurrent
copies are both handled. For a registration that means two confirmation emails to
the same buyer. Pin `replicas: 1` and leave the HPA off until
`FOR UPDATE SKIP LOCKED` lands in
[eventa-relay](../eventa-relay/src/relay/outbox-reader.repository.ts). The chart
should make this hard to get wrong, not just documented.

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

## Until this repo exists

Local development runs the whole platform from
[`eventa-api/docker-compose.yml`](../eventa-api/docker-compose.yml) (Postgres,
RabbitMQ, Mailpit) plus the four services started by hand — see
[how-services-connect.md](../eventa-docs/04-architecture/how-services-connect.md).

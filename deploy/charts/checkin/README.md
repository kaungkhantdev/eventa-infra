# `checkin` — the door-scan pool

The `api` image again, in its own Deployment and its own HorizontalPodAutoscaler.
That is the whole chart, and it is what
[`devops-infrastructure.md`](../../../../eventa-docs/07-deployment/devops-infrastructure.md)
§3.2 asks for:

> The **check-in pool is deliberately separate** so a door-scanning surge during
> a live event (bursty, latency-sensitive) autoscales and fails independently of
> the main `api` serving browse/checkout traffic — one tenant's on-site rush
> cannot starve another's checkout.

**This chart implements a specification; it does not make design decisions.** The
sources of truth are §1.2 (Helm layout), §3.1 (namespaces), §3.2 (workloads),
§3.3 (resources, probes, disruption, network), §5 (config and secrets), §6
(scaling) and §7 (environments) of that document, plus §3, §4.2, §4.3 and §5.1
of [`devops-ci-cd.md`](../../../../eventa-docs/07-deployment/devops-ci-cd.md).
Every non-obvious value in `values.yaml` cites the section it comes from. Where
this chart knowingly goes beyond the spec — the two custom HPA metrics, and the
rollout surge — the comment says so and why.

## How it is built

Everything it renders comes from the shared library chart, which is §1.2's
instruction: probes, HPA, PDB, NetworkPolicy and ExternalSecret live in one place
so the five workloads cannot drift apart. `templates/workload.yaml` is therefore
two lines, and the chart contributes values and guards rather than object
templates.

```
templates/workload.yaml     {{ include "checkin.guards" . }} + the library's workload
templates/_guards.tpl       the five things that are only wrong for THIS chart
values.yaml                 the spec baseline, identical in every environment
values-{dev,staging,prod}.yaml   what an environment supplies
values.schema.json          a verbatim copy of ../_library/values.contract.schema.json
```

`values.schema.json` is a copy because Helm applies a schema only from the chart
root and does not resolve a `$ref` to a file outside it. Keep it byte-identical:

```sh
diff deploy/charts/checkin/values.schema.json \
     deploy/charts/_library/values.contract.schema.json
```

## What it renders

Nine objects in staging and prod, eight in dev (which runs no HPA):

| Object | Notes |
| --- | --- |
| ServiceAccount | Holds the workload-identity binding when a cloud is chosen (§5) |
| ConfigMap | Non-secret config, hashed into the pod template so an edit rolls the pods |
| ExternalSecret | The api's `/eventa/<env>/api` path — the only route a credential takes in (§5) |
| Deployment | Rolling, `maxSurge: 25%`, `maxUnavailable: 0`, soft cross-AZ anti-affinity |
| Service | ClusterIP; the edge is CDN → WAF → load balancer → Ingress (§2) |
| Ingress | Its own hostname — see below |
| HorizontalPodAutoscaler | CPU + RPS + check-in queue depth (§3.2); absent in dev |
| PodDisruptionBudget | `minAvailable: 50%` (§3.3) |
| NetworkPolicy | This workload's allows only; the namespace default-deny is the api's |

**No migration Job, in any environment.** eventa-api owns every migration and
the api chart owns the single gated wave-1 `PreSync` Job (devops-ci-cd.md §5.1).
`migrationJob.enabled` stays false here and `_guards.tpl` fails the render if
anybody turns it on — see the guard table.

## Rendering it

The chart does not render from its own defaults, deliberately. Three values are
environment inputs and none of them has a safe default:

- **the image tag** — §1.2 promotes an environment by moving a pinned SHA tag in
  that environment's values file, and devops-ci-cd.md §4.1 makes it a PR against
  that file. A tag in `values.yaml` would be a fifth place the CI bot has to
  know about.
- **the data-subnet CIDRs** — the managed Postgres, Redis and RabbitMQ are not
  pods (§2), so each allow is an `ipBlock` whose range is a Terraform network
  module output (§1.1). The library refuses to render an enabled egress with no
  CIDR, because a NetworkPolicy rule with an empty peer list allows *every*
  destination.
- **the hostname and the secrets path** — per environment by definition (§5, §7).

So lint and template the way Argo CD renders it, with an environment's values:

```sh
helm dependency build deploy/charts/checkin

for env in dev staging prod; do
  helm lint     deploy/charts/checkin -f deploy/charts/checkin/values-$env.yaml -n eventa-$env
  helm template checkin deploy/charts/checkin -f deploy/charts/checkin/values-$env.yaml -n eventa-$env
done
```

`kubectl apply --dry-run=client` is **not** a usable check here, for the reason
[`_library/README.md`](../_library/README.md) already records: it resolves every
`kind` through API discovery against a live server, so with no cluster it fails
on connection refused before it validates anything.

```
$ helm template … | kubectl apply --dry-run=client -f -
error: error validating "STDIN": error validating data: failed to download
openapi: Get "http://localhost:8080/openapi/v2?timeout=32s": dial tcp
[::1]:8080: connect: connection refused
```

Offline schema validation needs `kubeconform` (bundled schemas, no cluster),
which this repo does not have yet. Until it does, `helm template` proves the
manifests parse and `_guards.tpl` plus `_validate.tpl` catch at render time most
of what the API server would have caught at apply time.

## The autoscaler

§3.2 fixes the signals — CPU, RPS, and a custom check-in queue depth — and the
prod floor of 2 that "scales hard for events". §6 adds the ceiling and the
stabilization windows. The numbers and the arithmetic behind them are commented
in `values.yaml`; the shape is:

| Environment | Floor | Ceiling | Signals |
| --- | --- | --- | --- |
| dev | — | — | no HPA; two replicas, fixed |
| staging | 1 | 5 | CPU + RPS + check-in queue depth |
| prod | 2 | 20 | CPU + RPS + check-in queue depth |

Scale-out has **no** stabilization window and may double the pool every 30s; a
gate opening is a step change, and the minute a 60s window would hold the pool
flat for is the minute with the longest queue. Scale-in waits ten minutes,
because an event's doors open per session and the lull between two sessions
looks exactly like the end of the rush.

### The two metrics that do not exist yet

**Read this before the first prod sync.** The HPA names two series that nothing
currently produces:

- `eventa_http_requests_per_second`
- `eventa_checkin_scan_queue_depth`

`eventa-api/src/modules/metrics/metrics.service.ts` registers only the two
outbox gauges (`eventa_outbox_lag_seconds`, `eventa_outbox_unpublished`) plus
prom-client's default process metrics. There is no HTTP request counter and no
check-in gauge. Separately, no document in `eventa-docs` names the Prometheus
adapter that would have to expose either series to the Kubernetes custom-metrics
API, so the names here follow the `eventa_` prefix the api already uses rather
than any published contract.

What that costs if it is deployed as-is: an HPA that cannot read a metric does
not ignore it. The controller reports `FailedGetPodsMetric`, sets
`ScalingActive=False`, and **declines to scale in** while any metric is
unreadable — scale-out still happens on CPU. The pool therefore climbs with
load, never comes back down, and parks at its high-water mark. That is a FinOps
problem (§8) rather than an outage, and it is silent unless somebody is watching
the HPA's conditions.

Three ways forward, in order of preference:

1. Ship the app-side metric and the adapter rule with this chart. The check-in
   routes are in `eventa-api/src/modules/check-in/`; the queue depth is the
   number that rises before CPU does, which is the entire reason §3.2 asks for a
   signal other than CPU.
2. Point the metric names at whatever the environment's adapter already serves,
   by overriding `hpa.metrics` in `values-<env>.yaml`.
3. Run on the CPU target alone until then: drop `hpa.metrics` in the environment
   overlay. The pool still autoscales and still fails independently of the api —
   it just reacts later than §3.2 intends.

Staging keeps all three signals on purpose. It is the environment for perf
checks (§7), so it is where a missing adapter rule should be discovered.

## What this chart deliberately does not do

- **Run migrations.** Covered above. The guard is the implementation of
  `eventa-infra/README.md`'s third warning.
- **Own the namespace default-deny.** `networkPolicy.defaultDeny` is
  namespace-wide, so exactly one release per namespace should own it, and
  `_library/README.md` nominates the api — every namespace that runs anything
  runs that. This chart's own NetworkPolicy is additive on top of it.
- **Egress to Stripe, PromptPay or the comms providers.** §3.3's last egress
  clause names no workloads, and the only routes pointed at this pool are the
  door's, none of which calls a payment provider. Left closed so that routing
  checkout traffic here fails loudly instead of quietly turning the pool into a
  second checkout pool with a door-scan autoscaler.
- **Claim a node pool or a priority class.** §6 says a separate node pool *can*
  back the burstable pool, and it should. The block is commented out in
  `values-prod.yaml` rather than written, because a `nodeSelector` naming a pool
  that does not exist leaves every replica Pending — the pool would not be
  isolated, it would be absent — and a `priorityClassName` naming a missing
  PriorityClass is rejected outright.
- **Use a canary.** devops-ci-cd.md §4.2 gives the canary to the api and this
  pool "Rolling (surge-friendly)". The surge is raised to 25% because replacing
  a 20-pod pool one pod at a time takes twenty readiness cycles, which would
  overlap the next door rush.
- **Terminate TLS.** §2 puts the certificates in the `edge` Terraform module in
  front of the load balancer, so `ingress.tls` is unset.

## Two things to know before go-live

**The scrape endpoint is reachable from the public hostname.** The api serves
`/api/v1/metrics` on the same port as everything else
(`eventa-api/src/modules/metrics/metrics.controller.ts`, which is `@Public` and
says so: "if it is ever published, it wants network policy in front of it"). The
Ingress routes the `/api/v1` prefix, and plain Ingress has no deny rule and no
mid-path wildcard, so neither this chart nor a NetworkPolicy can separate the
scrape path from the door's traffic — the port is the same. The place to block
it is the WAF in front of the load balancer (§2). The same applies to
`/api/v1/health/*`.

**Two of the NetworkPolicy's ingress rules differ only in a placeholder, and
both of them currently match nothing.** The ingress-controller allow and the
metrics-scraper allow both resolve to "the `platform` namespace, port `http`",
because the api serves traffic and metrics on one port and both the controller
and the observability agents live in `platform` (§3.1). §3.1 names neither
product, so the library gives each a `podSelector` of
`app.kubernetes.io/name: REPLACE-ME-ingress-controller` and
`REPLACE-ME-metrics-scraper` — the right shape with a deliberately wrong value,
because a namespace-only peer would also admit Argo CD and External Secrets and
`_library/templates/_validate.tpl` refuses that form.

They **fail closed**: no pod carries either label, so until both are replaced
this pool takes no inbound traffic at all — no door scans and no scrape. Replace
them once a controller and an observability stack are chosen; the marker string
is visible verbatim in the rendered object and in an Argo CD diff. Keeping them
as two rules rather than one still matters, so that narrowing or replacing one
does not silently change the other; NetworkPolicy rules union.

## The guards

`eventa-infra/README.md` asks the charts to "make this hard to get wrong, not
just documented". `_guards.tpl` fails the render on five things, each of which
applies cleanly to a cluster and then misbehaves. They are chart-specific
because `checkin` is the api chart's twin and sits next to four sibling charts
that are the obvious place to copy a block of values from.

| If somebody sets | What would happen | Where the rule comes from |
| --- | --- | --- |
| `migrationJob.enabled: true` | A second migration Job in the same PreSync phase as the api's, racing it against one database | devops-ci-cd.md §5.1; `eventa-infra/README.md` warning 3 |
| `component: api` | This release's Service load-balances door scans onto the api pool's pods, and its PDB counts the api's replicas | §3.2 — the component label is the only thing separating the two pools |
| `singleton.enabled: true` (the relay's setting) | One replica, no HPA, `maxSurge: 0` — a door surge served by a single pod | §3.2, §6; the relay's constraint is its unlocked outbox reader, not anything here |
| `deployment.enabled: false` (the api's setting) | A Service, an HPA and a PDB with no pods behind any of them | devops-ci-cd.md §4.2 — the canary is the api's, this pool rolls |
| `ingress.enabled` with no host | An Ingress with no rules: applies cleanly, routes nothing, 404 from the default backend | §7 — the hostname is per environment |

Verify them after a change to the library or the values:

```sh
cd deploy/charts/checkin
for v in migrationJob.enabled=true component=api singleton.enabled=true deployment.enabled=false; do
  helm template checkin . -f values-prod.yaml -n eventa-prod --set $v 2>&1 | head -1
done
```

The component and ingress checks are generic enough to belong in
`_library/templates/_validate.tpl` once a second chart wants them. They are here
because the library is shared and this chart is the only evidence so far that
they are needed.

## Environments

`eventa-dev`, `eventa-staging` and `eventa-prod` have overlays here. The other
two from §3.1:

- **`eventa-uat` has no overlay here, and that is an open gap rather than a
  design.** `argocd/environments/uat/checkin.yaml` already names
  `values-uat.yaml` in its `valueFiles`, and no Argo CD Application in this repo
  carries `helm.parameters`, so nothing substitutes for the file: that
  Application fails with "values file does not exist" on every sync, and its own
  header opens with `THIS APPLICATION CANNOT SYNC YET`. `argocd/README.md`
  tracks it under "Known gaps". §7 makes UAT prod-like with gated promotion, so
  the file is `values-staging.yaml`'s sizing with UAT's own hostname,
  `/eventa/uat/api` secret path and data-subnet CIDRs — four keys. Settle the
  CIDR scheme first; `argocd/README.md` says which overlays currently disagree
  and why adding another opinion before the Terraform network module exists
  makes that worse.
- **`preview-<pr>`** is created per PR and torn down on close (§7,
  devops-ci-cd.md §1.1), with scale-to-zero when idle (§8). That is the one
  environment where an HPA floor of 0 is correct, and the hostname is
  `pr-<n>.preview.eventa.dev` — both of which the CI job that creates the
  namespace should pass with `--set`, since there is no static file for an
  ephemeral environment.

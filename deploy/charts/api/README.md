# `api` — the core API chart

The NestJS modular monolith that serves browse, checkout, payments and auth.
Four of the five workloads roll; this one does not. `devops-ci-cd.md` §4.2 gives
the api a **canary** because it is "the integrity-critical, highest-blast-radius
surface", and §5.1 puts the **gated pre-deploy migration Job** here because
`eventa-api` owns every migration while `worker` and `relay` keep typed mirrors
of the tables they touch.

**This chart implements a specification; it does not make design decisions.**
The sources of truth are
[`devops-infrastructure.md`](../../../../eventa-docs/07-deployment/devops-infrastructure.md)
(§1.2 chart layout, §3.1 namespaces, §3.2 workloads and scaling signals, §3.3
resources/probes/disruption/network, §5 config and secrets, §6 scaling, §7
environments) and
[`devops-ci-cd.md`](../../../../eventa-docs/07-deployment/devops-ci-cd.md)
(§4.2 canary and its gates, §4.3 sync waves and rollback, §5.1 gated migrations,
§5.2 expand/contract, §8 rollback). Every value traceable to a document cites
its section in `values.yaml`.

Everything the five workloads share comes from
[`_library`](../_library/README.md) and is not reimplemented here. Read that
chart's README first; this one only covers what is specific to the api.

## What it renders

| Object | Source | Notes |
| --- | --- | --- |
| **Rollout** | `templates/rollout.yaml` | The canary. Replaces the Deployment, which is why `deployment.enabled: false`. |
| **AnalysisTemplate** | `templates/analysistemplate.yaml` | The §4.2 gates. Not rendered when `canary.analysis.enabled` is off. |
| ServiceAccount, ConfigMap, ExternalSecret, migration Job, Service, Ingress, HPA, PDB, 2× NetworkPolicy | `_library`, via `templates/workload.yaml` | One include; `deployment.enabled: false` is the only reason the set is not all eleven. |

Twelve objects per environment (eleven in dev, which ships no AnalysisTemplate).

The Rollout's pods are `eventa-library.podTemplate` — the identical pod spec the
other four workloads get, so the canary costs this chart a strategy block and
nothing else. That is the whole point of the library (§1.2): a change to a probe
or a security context happens in one file, not five.

## The canary

`devops-ci-cd.md` §4.2: 10% → 25% → 50% → 100%, analysis at each step, abort and
roll back on a failed gate.

```
setWeight 10 → analysis → setWeight 25 → analysis → setWeight 50 → analysis → (promote)
```

The 100% is not a step: after the last gate passes, the Rollout promotes the
canary ReplicaSet to the full replica count. From that point §8.1 applies
instead — a regression found at 100% is a feature flag flip or an image-digest
revert in the GitOps repo, not a rollout to abort.

**Weights are expressed by replica count, not by traffic routing.** §4.2 fixes
the percentages but no document chooses a service mesh or an ingress provider,
and a `trafficRouting` block naming one would commit this repo to that choice.
Without it, Argo Rollouts runs the weight as a share of the replicas behind the
one Service this chart renders: at the prod floor of three replicas (§3.2), a
10% step is one pod of three. Set `rollout.trafficRouting` — and
`canaryService`/`stableService` — once a provider exists and the weights become
exact.

### The gates

The thresholds are §4.2's, in `values.yaml` under `canary.analysis.metrics`,
passed to the AnalysisTemplate verbatim — the same idiom the library uses for
`hpa.metrics`, and for the same reason. §4.2 fixes what to measure; the PromQL
that measures it depends on series names belonging to whichever Prometheus an
environment runs, which no document names. A query in values is read and
corrected by the person who owns that Prometheus; a query buried in a template
is wrong invisibly.

| §4.2 gate | Rendered as | Threshold |
| --- | --- | --- |
| HTTP 5xx rate | `canary-5xx-rate` | ≤ 1% |
| …and not above baseline | `canary-5xx-vs-baseline` | canary − stable ≤ 0.5pp |
| p95 latency, checkout endpoints | `canary-checkout-p95-vs-baseline` | ≤ 1.2× stable |
| Pod readiness / crashloops | `canary-container-restarts` | 0 restarts on the canary revision |
| Sentry new-error rate | **not rendered** | needs a Sentry project and token — see below |
| Synthetic checkout probe | **not rendered** | needs the probe's address — see below |

The last two are left as documented, commented shapes in `values.yaml` rather
than guesses. Both need an endpoint no document names and a credential that does
not exist in this repo; a gate pointed at an invented URL errors on every run
and aborts every deploy, which from the outside is indistinguishable from a bad
build. `devops-observability-sre.md` §5 already runs a synthetic checkout
against a seeded tenant in Stripe test mode, so the second gate is a query over
that probe's own series once it is scraped.

### Two platform facts the gates depend on

Neither is a chart problem, and both are worth knowing before turning analysis on
in a new environment.

1. **The api emits no HTTP metrics yet.** Its registry holds
   `eventa_outbox_lag_seconds`, `eventa_outbox_unpublished` and `prom-client`'s
   process defaults
   (`eventa-api/src/modules/metrics/metrics.service.ts`) — there is no request
   counter and no duration histogram. Until there is, the first three gates
   return no data, which Argo Rollouts records as *inconclusive* rather than as a
   pass: the Rollout waits at 10% for a human instead of promoting an unmeasured
   build. That is the safe direction and it is what §4.2 asks for, but it does
   mean the first deploy into an environment with analysis on will pause.
2. **The scrape must carry `rollouts-pod-template-hash` into the series** (a
   `labelmap` over pod labels in a `kubernetes_sd` scrape config). Without it the
   canary and stable selectors match the same pods, every ratio is 1.0, and the
   gates pass unconditionally — which is worse than having no gates.

The same first fact is why `hpa.metrics` carries a warning: an HPA whose custom
metric cannot be fetched keeps scaling **up** on the metrics that resolve and
skips every scale-**down**, so a missing series looks like an api that scaled out
for an on-sale and never came back. `values-dev.yaml` therefore autoscales on CPU
alone.

## The migration Job

Rendered by the library, enabled only here. An Argo CD `PreSync` hook in sync
wave 1 with `backoffLimit: 0`, so a non-zero exit halts the sync and no api pod
ever starts against an un-migrated schema (§5.1). It reuses the api's image,
ConfigMap, Secret and ServiceAccount, because a migration runs the same code and
needs the same credentials; its pods carry `component: migration` so the Service
does not route live requests to them and the PDB does not count them.

`command: [npm, run, migrate]` is `eventa-api`'s only migration entry point —
the `migrate` script in its `package.json`, which runs `drizzle-kit migrate`
over `src/db/migrations` and tracks what it has applied, so a re-run is the no-op
§5.1 requires.

**One thing to carry into the image build:** `drizzle-kit` is a *devDependency*
in `eventa-api/package.json`, so a runtime image pruned to production
dependencies cannot run this command. Either the api image keeps its migration
tooling, or `eventa-api` ships a compiled migration entry point for this Job to
call. There is no Dockerfile in `eventa-api` yet, so this is a note for whoever
writes it.

§5.1 also asks for a lock timeout and a statement timeout. Those belong in the
migration's own database session, which this chart cannot reach — the connection
string arrives from the secrets manager (§5) and `drizzle-kit` opens it
directly. What the chart bounds is the Job: `activeDeadlineSeconds`, so a
migration blocked on a lock fails the gate instead of holding the deploy open.

## Values layout

`values.yaml` is the spec's prod sizing with nothing in it that names an
environment. Everything that only exists once an environment exists — the image
reference, the data-subnet CIDRs, the secret path, the hostnames, the Prometheus
address — is in `values-<env>.yaml`, because Argo CD always renders this chart
with one (§1.2: "Chart + per-env `values-<env>.yaml` in Git").

```sh
helm template api . -n eventa-prod -f values-prod.yaml
```

| File | Differs from the baseline in |
| --- | --- |
| `values-prod.yaml` | coordinates only — the baseline *is* prod sizing |
| `values-staging.yaml` | coordinates, plus a smaller replica floor (§8 FinOps; §7 allows replica count to differ) |
| `values-dev.yaml` | coordinates, plus one replica, CPU-only autoscaling, `LOG_LEVEL: debug`, and canary analysis off |

`values-uat.yaml` exists, and it had to: `argocd/environments/uat/api.yaml`
names it in `valueFiles` and no Argo CD Application in this repo carries
`helm.parameters`, so without the file that Application could not sync at all.
Its absence also left `eventa-uat` with **no namespace-wide default-deny
NetworkPolicy**, because that object is namespace-scoped and
`_library/README.md` puts it on the api — the one chart every namespace runs.
Like staging, the file differs from the baseline only in sizing and
coordinates (§7).
`preview-<pr>` namespaces are generated by the Argo CD `ApplicationSet` PR
generator (`devops-ci-cd.md` §1.1) and differ in one structural way: their
Postgres, Redis and RabbitMQ are throwaway pods in the preview namespace rather
than managed services, so they declare `networkPolicy.egress.toPods` instead of
CIDRs.

**Values marked `PLACEHOLDER` are not decisions.** They are outputs of Terraform
modules that have not been run — this repo has no `terraform/`, no cloud account
is provisioned, and §1.1 deliberately names no provider. They are written as
syntactically valid values rather than left blank because the library refuses an
empty CIDR list: a NetworkPolicy rule with no peer allows every destination
rather than none, so a blank would be the one mistake that fails open.

## What this chart refuses to render

`templates/_validate.tpl`, on top of the library's own checks. Each one is a
manifest a cluster would accept and then get wrong.

| It fails if | Because |
| --- | --- |
| a probe or the metrics path is not under `/api/v1` | `eventa-api/src/main.ts:18` sets that global prefix. An unprefixed readiness probe 404s, the pod never goes ready, and the canary stalls while the pods serve traffic correctly on the real path. |
| both a Rollout and a Deployment are enabled, or neither | Two controllers with one selector delete each other's pods; none means a Service, HPA and PDB with nothing behind them. |
| the HPA's `scaleTargetRef` names the kind this chart does not render | An HPA on a missing object is created happily, reports `FailedGetScale`, and scales nothing — through the on-sale burst §6 exists for. |
| `migrationJob.enabled` is false in a real namespace, or it has no command | The api owns every migration; with the Job off, the api rolls first and fails on a table that does not exist. With no command the Job runs the image's entrypoint — a server that never exits 0, so the sync hangs. |
| `config.env` carries a migration or schema-sync switch | §5.1: migrations never run in app startup. A boot-time migration runs once per replica, so a 10% canary migrates from the new revision while the stable one serves. |
| `argocd.syncWave` is not 2 | §4.3 fixes (1) migration Job → (2) api/worker/relay → (3) web. |
| canary steps are empty, out of range, or not increasing | An empty list is a rolling update wearing a Rollout's name; 100 is the completion, not a step. |
| analysis is on with no gates, or a Prometheus gate has no address | An AnalysisTemplate with no metrics succeeds unconditionally — a gate that always says yes. An unreachable provider aborts every deploy for a reason unrelated to the build. |
| `eventa-prod` gets no HPA, a floor below 3, or analysis off | §3.2's prod minimum is 3; §4.2 requires the gates on the payments surface. |
| a real namespace gets no ExternalSecret, no Ingress, no data-store egress, or no ingress-controller allow | Each renders an api that deploys green and does not work: no credentials to boot, no public route, a readiness probe failing on its first `select 1`, or a default-deny policy dropping every request. |
| `component` is anything but `api` | The check-in pool runs the same image from its own chart (§3.2); from this one it would share the api's canary, HPA and pod selector — exactly the isolation that section exists to create. |

## Verifying a change

```sh
helm dependency update deploy/charts/api
helm lint deploy/charts/api
for e in dev staging prod; do
  helm template api deploy/charts/api -n eventa-$e -f deploy/charts/api/values-$e.yaml
done
```

`values.schema.json` is the library's values contract plus this chart's two
extra keys, so `helm lint` and `helm template` type-check the values. **Re-copy
it when the library's contract changes** — it is a copy, not a reference, because
Helm applies a dependency's schema to that dependency's own values sub-tree.

`kubectl apply --dry-run=client` does **not** work here, and not because of
anything in the chart: kubectl resolves every `kind` through API discovery
against a live server, so with no cluster it fails on `connection refused`
before it validates a single field — with `--validate=false` as well, which only
skips the OpenAPI schema fetch and not the RESTMapper. Offline schema validation
needs an out-of-cluster validator with bundled CRDs (`kubeconform`), which is
not installed in this repo yet; until it is, `helm template` plus a structural
pass over the rendered YAML is the check, and `_validate.tpl` already catches at
render time most of what the API server would catch at apply time.

## The api's own numbers

From §3.2 and §3.3, for reference while reading `values.yaml`.

| | |
| --- | --- |
| Image | `api` |
| Min replicas (prod) | 3 |
| Resources | 500m / 2000m CPU · 512Mi / 1Gi memory |
| Scaling signal | CPU + RPS + p95 latency |
| Probes | readiness `/api/v1/health/ready` · liveness `/api/v1/health/live` · startup on (cold NestJS boot) |
| Disruption | `minAvailable: 50%` |
| Strategy | canary 10/25/50 (§4.2) |
| Sync wave | 2 (the migration Job is 1) |

One gap worth knowing: `eventa-api/src/health/health.service.ts` pings Postgres
only, while §3.3 describes readiness as checking DB/Redis/broker. A Redis or
RabbitMQ outage therefore does not take a pod out of the Service today. That is
a gap in the service rather than in the chart, which points at the endpoint the
section specifies.

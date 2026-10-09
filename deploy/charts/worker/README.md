# `worker` — RabbitMQ consumers

The consumer pool from `devops-infrastructure.md` §3.2: notifications, calendar
and indexing, plus the scheduled sweeps the same image runs (order expiry,
waitlist offers, scheduled announcements). One Deployment, one HPA on CPU and
RabbitMQ queue depth, a floor of two replicas in every environment.

**This chart implements a specification; it does not make design decisions.**
The sources of truth are
[`devops-infrastructure.md`](../../../../eventa-docs/07-deployment/devops-infrastructure.md)
(§3.1 namespaces, §3.2 workloads, §3.3 resources/probes/disruption/network, §5
config and secrets, §6 scaling, §7 environments, §8 FinOps),
[`devops-ci-cd.md`](../../../../eventa-docs/07-deployment/devops-ci-cd.md)
(§4.1 promotion, §4.3 sync waves, §5.3 draining) and
[`devops-observability-sre.md`](../../../../eventa-docs/08-maintenance/devops-observability-sre.md)
(§1 metrics, §2 queue-depth and DLQ signals, §7.2 HA, §7.3 capacity review).
Every value traceable to a document cites its section in the values file. There
is one place this chart knowingly departs from the spec — the probes — and it is
[documented below](#the-probe-discrepancy).

## Rendering it

```sh
helm dependency update deploy/charts/worker

helm lint     deploy/charts/worker -f deploy/charts/worker/values-prod.yaml
helm template worker deploy/charts/worker -f deploy/charts/worker/values-prod.yaml -n eventa-prod
```

**Always pass an environment file.** `values.yaml` is the production baseline,
not a deployable configuration: three facts belong to an environment rather than
to a design, and they are absent on purpose so that a render without one fails
instead of inheriting somebody else's.

| Absent from `values.yaml` | Why | Where it comes from |
| --- | --- | --- |
| `image.tag` (declared, left empty) | §1.2 makes moving this pinned SHA *the* promotion; ci-cd §2.1 stage 11 has the bot write it | `values-<env>.yaml` |
| `externalSecret.dataFrom` | §5 gives each environment its own path; a default here would be one environment's secrets inherited by all of them | `values-<env>.yaml` |
| the data-subnet CIDRs | §2 puts the stores outside the cluster; the ranges are Terraform network-module output | `values-<env>.yaml` |

`helm lint` with no environment file therefore fails by design, at `/image` with
`'anyOf' failed`. Expect the sub-message `at '/image/tag': minLength: got 0,
want 1` rather than a missing property: this chart's `values.yaml` declares
`tag` and leaves it empty, so the schema rejects the empty string alongside the
unset `digest`. (`web`, `checkin` and `relay` omit the key entirely and report
`missing property 'tag'` instead — the same refusal, a different message.)

## What this chart adds, and what it inherits

The chart is four values files, one guard file, and a single line of template:

```
{{- include "eventa-library.workload" . }}
```

Everything structural comes from [`_library`](../_library), which is what §1.2
asks for. **Absent from `values.yaml` means inherited, not forgotten** — these
are already correct for the worker and are listed here so the omissions are not
read as oversights:

| Inherited from `_library/templates/_defaults.tpl` | Value | Spec |
| --- | --- | --- |
| `pdb.minAvailable` | `50%` | §3.3 |
| `updateStrategy` | `RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` | §3.3; ci-cd §4.2 gives the worker rolling updates |
| `antiAffinity` | soft, zone-weighted | §3.3 "anti-affinity spreads replicas across AZs" |
| `hpa.cpu.targetAverageUtilization` | `70` | §3.2's CPU half of the signal |
| `hpa.behavior` | fast out, 300s stabilization in | §6 "stabilization windows to avoid flapping" |
| `probes.readiness` / `probes.liveness` | `GET /health/ready` / `GET /health/live` | §3.3 |
| `networkPolicy.egress.dns`, `ingress.fromMetricsScraper` | on | observability §1; `platform` per §3.1 |
| `podSecurityContext`, `securityContext` | non-root, read-only root, all caps dropped | ci-cd §3 |
| `migrationJob` | off | eventa-api owns every migration; the worker keeps typed mirrors |
| `service` | **off, set explicitly** | §3.3 routes ingress to web/api/checkin only |

## Environments

| File | Namespace | What actually differs |
| --- | --- | --- |
| `values.yaml` | — | the production baseline |
| `values-prod.yaml` | `eventa-prod` | tag, `/eventa/prod/worker`, CIDRs, mail identity |
| `values-staging.yaml` | `eventa-staging` | the above for staging, plus `LOG_LEVEL: debug` and a ceiling of 4 |
| `values-uat.yaml` | `eventa-uat` | the above for UAT, plus a ceiling of 3 and no queue-depth metric; keeps `NODE_ENV: production` and declines staging's `LOG_LEVEL: debug` |
| `values-dev.yaml` | `eventa-dev` | the above for dev, plus `NODE_ENV: development`, `EMAIL_PROVIDER: log`, no queue-depth metric, no external egress, ceiling of 2 |

All four of §7's parity environments have an overlay here, so
`argocd/environments/uat/worker.yaml` renders like the other three. **It is
worth being precise about how UAT is configured, because this README used to
describe it wrongly.** An earlier version presented UAT as a deliberate design
in which this chart's staging overlay was synced with the secret path
overridden through the Argo CD Application. No such arrangement ever existed or
could have: that Application carries no `helm.parameters`, and **no Application
anywhere under `argocd/` carries one**, because §1.2 makes the chart-plus-values
pair the unit of deployment and §5's per-environment secret path is the entire
least-privilege boundary — an Application that could rewrite it from outside
would be a hole in that boundary, not a convenience. What actually happened is
that the Application named a `values-uat.yaml` that did not exist and reported
"values file does not exist" on every sync attempt. UAT is now configured the
way every other environment is: by its own overlay in this directory.

That overlay derives from `values-staging.yaml`, because §7 puts staging at the
nearest parity, and changes what §7 allows an environment to change — "sizing,
replica counts, retention, and data sensitivity" — plus the coordinates: the
image tag, `/eventa/uat/worker`, the CIDRs, and the mail sink. The one thing it
pointedly does *not* inherit is staging's `LOG_LEVEL: debug`: §7 anonymises
staging's dataset but calls UAT's "curated realistic; masked", and its users are
product and selected stakeholders, so handler-level logging of their
registrations would put more into the log pipeline than an acceptance test
needs.

`preview-<pr>` is different and really is deliberate: §7 scales previews to zero
when idle, which is an `hpa.minReplicas: 0` on the preview `ApplicationSet`, not
a file here.

Three decisions worth knowing:

**The replica floor does not drop below 2 in any environment.** §8 asks for
smaller non-prod replica counts, and that happens at the *ceiling*.
`observability §7.2` asks for "≥ 2 replicas per Deployment" without carving out
non-prod, and more concretely: §3.3's `minAvailable: 50%` against a floor of 1
rounds up to 1, which leaves zero voluntary disruptions, so every node drain in
that namespace would block until somebody deleted the pod by hand. That is the
trade the relay chart has to live with; this one does not have to.

**`minReplicas`, not `replicas`.** The library omits `replicas` from the
Deployment whenever an HPA exists, so that Argo CD self-heal (§1.3) cannot scale
the workload back down in the middle of the burst the HPA just scaled up for.
§3.2's "min replicas (prod) 2" therefore lands on `hpa.minReplicas`; a
`replicas` value here would be dead config that reads as if it did something.

**Dev drops the queue-depth metric, and that is a correctness fix rather than a
simplification.** An external metric the Prometheus adapter cannot resolve does
not merely report `<unknown>`: while any metric read is failing the HPA stops
scaling **in** altogether. Dev has no committed adapter rule — no document names
an adapter at all — so leaving the metric in would let one CI run's burst scale
the worker out and pin it there, the opposite of §8's "non-prod scales down".

## The probe discrepancy

**`devops-infrastructure.md` §3.3 says "Workers/relay use exec/TCP checks (no
HTTP server) plus broker-connection health". The parenthetical is out of date
for the worker, and this chart uses HTTP probes.**

That sentence is a factual claim about the code, and for the worker it is false:

- `eventa-worker/src/main.ts:18` calls `app.listen(port)`, on `PORT` —
  3100 by default (`src/config/env.validation.ts:9`).
- `eventa-worker/src/health/health.controller.ts:27,36` serves `GET /health/live`
  and `GET /health/ready`, the exact two endpoints §3.3 specifies.
- `src/health/health.service.ts:35` makes readiness check Postgres **and**
  RabbitMQ, which is §3.3's "checks DB/Redis/broker".
- `src/health/liveness.ts:37` makes liveness report *"attached to the queue"*
  rather than *"the event loop still turns"* — which is precisely the
  "broker-connection health" the same sentence requires.

Following the letter instead would produce a chart that is worse on both halves
of that sentence:

- An **exec** probe has nothing to run. There is no health CLI in
  `eventa-worker` — the only script in the repo is `scripts/email-doctor.sh` —
  so a command invented here would fail on every pod. Readiness would never
  pass, the rollout would stall at the first new pod, and the service would
  never deploy at all.
- A **TCP** probe on 3100 would succeed because the port is open, and would
  assert nothing about Postgres or the broker. It cannot carry
  "broker-connection health", so it satisfies neither half.

So the chart uses the endpoints that exist. The `_library` README reached the
same conclusion independently while building the shared probe template; §3.3 is
accurate for the relay, which really is an application context with no HTTP
server, and stale for the worker.

Two consequences of the worker's liveness endpoint being a dependency check,
which §3.3 generally warns against:

- A broker blip does **not** restart anything. `src/health/liveness.ts:9` holds
  a 60s detachment grace before reporting failure, and the probe then needs
  3 × 20s to act — so a detached worker is restarted about two minutes in, and
  nothing restarts for a failover shorter than that.
- A broker outage longer than ~2 minutes **does** restart every worker pod at
  once. They come back and reconnect, and no work is lost: the events are still
  in the outbox (ci-cd §5.3). This is a deliberately accepted cost of the
  application's own design, recorded here because it is the one way this chart
  can cause a simultaneous restart.

The startup probe (§3.3 requires one on api and worker) points at
`/health/live`, which returns 200 as soon as the server is up —
`src/health/liveness.ts:41` reports ok while the consumer has not attached yet.
So it means "the process is serving", which is a startup probe's job, and
readiness decides whether the pod is usable. Note the gap that leaves: a worker
whose HTTP server is up but which **never** attaches keeps liveness green
forever. Readiness catches it instead — `rabbitmq: down` means the pod never
becomes Ready, and with `maxUnavailable: 0` the rollout halts with the old pods
still working.

## Scaling

§3.2's signal is CPU + RabbitMQ queue depth, floor 2. CPU comes from the
library. Queue depth is an `External` metric in `values.yaml`:

```yaml
- type: External
  external:
    metric:
      name: rabbitmq_queue_messages
      selector:
        matchLabels: { queue: eventa.worker }
    target: { type: AverageValue, averageValue: "100" }
```

`rabbitmq_queue_messages` is the exporter series whose definition is literally
observability §2's "ready + unacked messages per queue", and §2 names the
RabbitMQ exporter as the source. **The name still has to be confirmed against
the Prometheus adapter an environment runs** — the built-in
`rabbitmq_prometheus` plugin calls the same quantity
`rabbitmq_detailed_queue_messages` — because the consequence of getting it wrong
is not a visibly broken HPA; it is an HPA that scales out on CPU and never
scales in. If an environment uses a non-default vhost (previews get one each,
ci-cd §1.1), the selector needs a `vhost` label too, or it sums every vhost's
copy of the queue name.

`averageValue: "100"` reads "scale until no replica has more than 100 messages
waiting". With the consumer's prefetch of 10
(`src/config/env.validation.ts:21`) that is ten prefetch windows of backlog per
replica. It is a starting point in the sense §3.3 means — re-tuned from
Prometheus by §6's right-sizing loop.

**What the HPA does not cover.** `eventa-infra/README.md` is explicit that the
worker's alert is DLQ **rate**, not depth, because depth only ever climbs and
everyone learns to ignore it. The DLQ is not a scaling signal and is not in this
chart: a poison message does not get better with more consumers. Alerting lives
in observability §2 (DLQ depth > 0 warn, > 10 or rising 15 min page) and the
metric the worker publishes for it is `eventa_consumer_attached`
(`src/metrics/metrics.service.ts:41`).

## The five guards

`templates/_guards.tpl` adds five render-time refusals on top of the ones in
`_library/templates/_validate.tpl`, which already cover everything common to the
five workloads. Each one here is a failure a cluster accepts and then gets wrong
*quietly*,
which is the test `eventa-infra/README.md` sets for the relay guard: make it
hard to get wrong, not just documented. All five are verified firing.

(The file's own header and its inline numbering still say "four": they count the
four below the `migrationJob` check and omit that check itself, which is the
same refusal `web`, `relay` and `checkin` each count among their own. Eight
`fail` call sites implement these five, because three of the five fail on two
distinct conditions.)

| Guard | The silent failure it prevents |
| --- | --- |
| `migrationJob.enabled` must stay false | The Job carries no command, so it runs the worker image's entrypoint — a second consumer competing for the same queues, started outside the Deployment the HPA and PDB govern. `eventa-api` owns every migration and the api chart owns the single wave-1 `PreSync` Job (ci-cd §5.1). |
| `config.env.PORT` must equal the container port named `http` | The pod serves on one port and is probed on another. Readiness never passes, the rollout stalls on the first new pod, and the container log shows a worker that started normally. |
| The HPA's `queue` selector must equal `config.env.RABBITMQ_QUEUE` | The autoscaler tracks a queue nobody drains. The real backlog grows with no scale-out, and both objects look correct in isolation. |
| `EMAIL_PROVIDER` may not be `log` when `NODE_ENV=production` | The log provider records a send and drops the message. eventa-worker refuses to boot on this (`src/config/env.validation.ts:148`); this moves the refusal from a post-sync crash loop to a failed render. |
| `EMAIL_FROM` must be set, and not a `.local` sender, when `NODE_ENV=production` | **The application does not catch this one.** Its default is `no-reply@eventa.local` (`src/config/env.validation.ts:99`) — valid syntax on a domain that does not exist, so every message fails SPF/DKIM alignment and is junked at the recipient while the provider accepts it and the handler counts a success. |

The last two key off `NODE_ENV`, the same switch eventa-worker keys its own
production refusals off. Telling the application it is in production therefore
holds this chart to production's requirements one render earlier than the
application does — in CI, or in an Argo CD diff.

## Before the first production sync

Four values in this chart are placeholders that only the platform team can
resolve. Each is marked in the values file it lives in.

1. **`image.tag`** — `sha-0000000` in all four environment files. Deliberately
   a SHA no build produces, so a release synced before its first promotion fails
   to pull rather than quietly running something else.
2. **The data-subnet CIDRs** — one `/24` per availability zone, to be replaced
   with the Terraform network module's output. dev, staging and UAT name AZ 1
   alone, because §8 runs them on single-node data services and there is no
   standby in another zone to allow; production names all three
   (`10.40.1.0/24`, `10.40.2.0/24`, `10.40.3.0/24`), because §4 gives it a
   multi-AZ Postgres standby and a three-node RabbitMQ cluster, so its endpoint
   moves between zones. This chart agrees with `api`, `checkin` and `relay`
   range for range in every environment, which it did not always — change the
   scheme in all four charts in one commit or not at all. Too narrow fails
   loudly on the first deploy; too broad fails silently, by granting the worker
   reach into the rest of the VPC.
3. **`serviceAccount.annotations`** — empty. §5 grants least-privilege access to
   `/eventa/<env>/*` through workload identity, and §1.1 names the mechanism
   neutrally ("IRSA/workload-identity") because no cloud has been chosen, so
   this chart does not guess at the annotation key. Until it is set, the External
   Secrets Operator falls back to its controller's own identity, which is broader
   than §5 allows.
4. **`EMAIL_FROM` and `PUBLIC_WEB_URL`** — no document in `eventa-docs` states
   the production hostname. Two domains appear there and neither is one:
   `eventa.co.th` only as test data (`06-testing/test-cases.md:503`), and
   `eventa.dev` only as the PR-preview zone (`devops-ci-cd.md` §1.1,
   `pr-<n>.preview.eventa.dev`). So the four non-production overlays extrapolate
   from `eventa.dev` — this chart's UAT overlay sends mail as
   `Eventa UAT <no-reply@uat.eventa.dev>` — while production uses two different
   placeholders on purpose. `PUBLIC_WEB_URL` takes the reserved zone
   `www.eventa.invalid`, the one every chart that names a hostname shares —
   `api`, `checkin`, `web` and this one, ten lines between them, while `relay`
   names no hostname at all; `EMAIL_FROM` takes
   `REPLACE_WITH_PRODUCTION_MAIL_DOMAIN` instead, because `templates/_guards.tpl`
   check 4 refuses a `.invalid` sender under `NODE_ENV=production` — and it is
   right to, since a valid address on a domain that resolves nowhere is accepted
   by the provider and junked at the recipient, whereas an unparseable token is
   rejected loudly at submission. Both stand for the same undecided name.

## Not yet declared, on purpose

Two egress allows a reader might expect are absent, because nothing in the image
sends the traffic yet and §3.3 allows no undeclared path either way:

- **Port 443.** There is no SMS provider configured (`SMS_PROVIDER` is unset,
  which eventa-worker resolves to `off` in production —
  `src/config/env.validation.ts:123`). Turning on `twilio` needs the credentials
  at the secret path *and* 443 added here, or every text fails on a blocked
  connection.
- **OTLP to the collector in `platform`.** The library sets `OTEL_SERVICE_NAME`
  and `OTEL_RESOURCE_ATTRIBUTES`, and observability §1 lists the worker under
  Traces — but `eventa-worker/package.json` has no `@opentelemetry/*`
  dependency, so those variables are inert today and nothing dials a collector.
  Add a `networkPolicy.egress.toPods` entry for `platform` on 4317/4318 in the
  same change that adds the SDK, or the first trace is dropped by this policy.

## Verifying a change

```sh
helm dependency update deploy/charts/worker
for e in dev staging uat prod; do
  helm lint deploy/charts/worker -f deploy/charts/worker/values-$e.yaml -n eventa-$e
  helm template worker deploy/charts/worker -f deploy/charts/worker/values-$e.yaml -n eventa-$e
done
```

All four environments render the same **7 objects** — ConfigMap, Deployment,
ExternalSecret, HorizontalPodAutoscaler, NetworkPolicy, PodDisruptionBudget and
ServiceAccount. Two absences are deliberate: no Service, because §3.3 routes
ingress to web, api and checkin only, and one NetworkPolicy rather than the
api's two, because the namespace-wide default-deny belongs to the api chart (the
one chart every namespace runs) and this policy is additive on top of it.
Verified with helm 4.3.0.

`kubectl apply --dry-run=client` is **not** usable with no cluster, and not
because of a flag: it resolves every `kind` through API discovery, so it fails
on `connection refused` before it validates anything, with `--validate=false`
and `--validate=ignore` alike. Server-side schema checking needs either a
cluster or an offline validator with bundled schemas — **`kubeconform`**, which
belongs in ci-cd §2.1's stage 10 next to tfsec and Checkov and is not installed
in this repo yet. Until it is, `helm template` plus a structural pass over the
rendered YAML is the check, and `_validate.tpl` plus `_guards.tpl` catch at
render time most of what the API server would have caught at apply time.

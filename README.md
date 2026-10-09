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
> **Known gaps.** Two are open; two are closed and kept on the list, because
> each is a failure mode this repo is likely to recreate:
>
> 1. **The production domain is undecided, and so is the production mail
>    sender.** No document in `eventa-docs` names a production hostname —
>    `eventa.co.th` appears only as fixture data
>    (`06-testing/test-cases.md:503`), and `eventa.dev` is named only for PR
>    previews (`devops-ci-cd.md` §1.1, `pr-<n>.preview.eventa.dev`). So
>    production points at the reserved zone `eventa.invalid`, and
>    `worker/values-prod.yaml` carries
>    `EMAIL_FROM: Eventa <no-reply@REPLACE_WITH_PRODUCTION_MAIL_DOMAIN>`. The
>    two placeholders differ on purpose: the worker's guard refuses a
>    `.invalid` sender under `NODE_ENV=production`, because a valid address on a
>    domain that resolves nowhere is accepted by the provider and junked at the
>    recipient, while a token that is not a parseable domain is rejected loudly
>    at submission.
>
>    **Renaming it is ten lines across four `values-prod.yaml` files — not one
>    line per chart.** The ten are not spread evenly, and the uneven part is
>    what gets missed: `api` has **4** (`PUBLIC_WEB_URL`, `PUBLIC_API_URL`,
>    `CORS_ORIGINS` and the `api.` ingress host), `checkin` has **4** (the same
>    three config keys plus the `checkin.` ingress host), `web` has **1** (the
>    `www.` ingress host), `worker` has **1** (`PUBLIC_WEB_URL`), and `relay`
>    has **0** — it has no `config:` block in `values-prod.yaml` at all, because
>    it serves no HTTP and writes no links. Edit one line per chart and
>    `PUBLIC_API_URL`, `CORS_ORIGINS` and two ingress hosts stay on
>    `eventa.invalid`, which fails in the two ways a half-rename always fails:
>    the browser is handed an API origin that resolves nowhere, and the api
>    rejects the real web origin as cross-site. Enumerate them before editing —
>    the second `grep` drops the comment lines that merely discuss the
>    placeholder:
>
>    ```sh
>    grep -rn "eventa.invalid" deploy/charts/*/values-prod.yaml | grep -v ':[0-9]*: *#'
>    ```
>
>    Mail from the new domain is only delivered once the provider holds its SPF
>    and DKIM records.
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
> 4. **Fixed: UAT is no longer short two overlays.** `checkin` and `worker` were
>    built with dev, staging and prod only, so their
>    `argocd/environments/uat/*.yaml` Applications named a `values-uat.yaml` that
>    did not exist and reported `values file does not exist` on every sync. Both
>    overlays now exist and **all 20 chart/environment pairs render.** The cost
>    while it was open is the part worth remembering: §7 lists four parity
>    environments, so a chart built for three leaves a namespace silently
>    incomplete rather than visibly broken. With no `worker` release in
>    `eventa-uat` a registration produced a green page and no email — the api
>    wrote its outbox row and the relay published it, and the `eventa.worker`
>    binding that image declares was simply absent, so the topic exchange
>    dropped the message. **Adding an environment means adding an overlay to all
>    five charts**, and `argocd/README.md`'s render loop is what catches a
>    chart that was missed.
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

There are **four** places where these charts do not do what one of those
documents says — two because the document is wrong, two because it asks for
something the service cannot yet do. All four are listed under **warning 4**,
with the two upstream corrections they still need. Nothing else in these charts
departs from the documents. The relay's replica count used to head that list and
no longer belongs on it: §3.2 has been corrected and now says what the chart
does.

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
# Error: execution error at (relay/templates/workload.yaml:18:4): SINGLETON GUARD — refusing to render the `relay` chart.
#
# replicas is set to 2, and this workload is declared a singleton.
#
# Why: fetchBatch takes no row lock, so a second replica selects the same outbox rows and publishes every event twice. Consumers dedupe only after the first copy completes.
#
#   [lines 6–29 of 30 elided: the two source citations below, the §3.2 quotes,
#    and the three-step lift order]
#
# Use --debug flag to render out invalid YAML
```

Helm puts the location and the first line of the message on **one** line, so
`grep SINGLETON` finds the banner and the file:line together. The location is
`workload.yaml:18`, which is the `eventa-library.workload` include and not the
`relay.guard` include on line 17 — because this particular refusal lives in the
library rather than in the relay's own guard. That split is the thing to know
when you are reading one of these errors:

**There are six refusals, they live in two files, and the line number tells you
which file you are in.**

| `--set` that trips it | Refused in | Reported at |
| --- | --- | --- |
| `replicas=2` — any explicit value above 1, in a values file or on the command line | `deploy/charts/_library/templates/_validate.tpl:328` | `workload.yaml:18:4` |
| `hpa.enabled=true` | `deploy/charts/_library/templates/_validate.tpl:331` | `workload.yaml:18:4` |
| `updateStrategy.rollingUpdate.maxSurge=1` — a surge *is* a second replica | `deploy/charts/_library/templates/_validate.tpl:345` | `workload.yaml:18:4` |
| `singleton.enabled=false` | `deploy/charts/relay/templates/_guard.tpl:32` | `workload.yaml:17:4` |
| `migrationJob.enabled=true` — the Job runs the relay image's own entrypoint, so it is a second publisher that never touches the replica count | `deploy/charts/relay/templates/_guard.tpl:35` | `workload.yaml:17:4` |
| `replicaCount=2` — Helm's conventional key name and not this library's; it used to be accepted and silently ignored, which left the manifest right and the operator's belief about it wrong | `deploy/charts/relay/templates/_guard.tpl:38` | `workload.yaml:17:4` |

The library's three are gated on `singleton.enabled`, and that is precisely why
the relay's three are not: turning that switch off would otherwise disable the
other half of the set, so the relay's own file refuses the switch itself. That
is also why the relay's three report the *earlier* line — `_guard.tpl` runs from
`workload.yaml:17`, before the library's own validation on line 18 gets a say.

Re-run the whole set rather than trusting the count; each line must print a
refusal and exit non-zero:

```sh
for s in replicas=2 hpa.enabled=true updateStrategy.rollingUpdate.maxSurge=1 \
         singleton.enabled=false migrationJob.enabled=true replicaCount=2; do
  helm template relay deploy/charts/relay -n eventa-prod \
    -f deploy/charts/relay/values-prod.yaml --set "$s" >/dev/null 2>&1 \
    && echo "RENDERED (guard hole) $s" || echo "refused $s"
done
# refused replicas=2
# refused hpa.enabled=true
# refused updateStrategy.rollingUpdate.maxSurge=1
# refused singleton.enabled=false
# refused migrationJob.enabled=true
# refused replicaCount=2
```

There is also no Argo CD route to any of them: no Application in `argocd/`
carries a `helm.parameters` block, so the replica count cannot be overridden
from outside the values files the chart validates.

**The guard stops at the cluster boundary, and production has no net past it.**
Every one of those six refusals happens at *render* time, and `kubectl scale`
never renders the chart. In `eventa-dev`, `eventa-staging` and `eventa-uat`
Argo CD self-heal is the backstop — a hand-scaled relay goes back to the chart's
literal `1` on its own. **None of the five service Applications in
`argocd/environments/prod/` carries an `automated` block**, so nothing reverts
anything in `eventa-prod`: §1.3 asks for both a gated production sync and
self-heal, Argo CD cannot give both, and
[argocd/README.md](argocd/README.md) records that the gate wins. The prod
*root* in [argocd/apps/prod.yaml](argocd/apps/prod.yaml) does carry
`automated: {prune: true, selfHeal: true}` and that is not the hole it looks
like: the root renders Application objects into `platform` and nothing into
`eventa-prod`, so its self-heal reverts a deleted child Application, never a
hand-scaled Deployment. A
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

**4. The charts and the documents still disagree in four places — and the
relay's replica count is no longer one of them.** That disagreement used to be
this warning's whole subject, so it is recorded here rather than quietly deleted:
anyone who remembers this file arguing at length that §3.2 was wrong about the
relay should know the argument was won upstream and the text has been retired.

What §3.2 and §6 once said, and what they say now:

| Entry | Then | Now |
| --- | --- | --- |
| `devops-infrastructure.md` §3.2, relay row | minimum **2** replicas, scaling signal "CPU + outbox lag" | "**exactly 1** — a fixed count, not a minimum", scaling signal "**None** — no HPA" |
| `devops-infrastructure.md` §6, Pods row | HPA per service, relay included | "**HPA per service**, except the singleton `relay` which has none (§3.2)" |
| `devops-infrastructure.md` §6, Consumers row | "`relay` scales with outbox lag" | the `relay` "**does not scale at all**"; lag "is an alerting signal, not a scaling signal" |
| `devops-ci-cd.md` §0, relay row | "1 Deployment + HPA (singleton-safe)" | "1 Deployment, **exactly 1 replica, no HPA** — a singleton" |

§3.2 goes further than agreeing: it states that "the `relay` is a singleton and
must not be scaled", spells out the lift condition in the same terms this repo
uses, and documents this repo's own render guard — the chart "fails to render if
the replica count is raised or its HPA enabled, rather than trusting this table".

**The guard stays, and for exactly the reason it always had, because that reason
was never the document.** It is the reader:

| Evidence | What it says |
| --- | --- |
| [`eventa-relay/src/relay/outbox-reader.repository.ts:25`](../eventa-relay/src/relay/outbox-reader.repository.ts) | `fetchBatch` selects pending rows on `isNull(outboxEvents.publishedAt)`. There is no `FOR UPDATE SKIP LOCKED`, so two readers polling at the same time return the **same rows**. |
| [`eventa-relay/src/main.ts:20`](../eventa-relay/src/main.ts) | "Scaling this safely needs `FOR UPDATE SKIP LOCKED` in the reader first." |

A second replica double-publishes every outbox message: both select the row, both
publish it, both mark it published. Consumers dedupe on message id but only
*after* the first copy has been handled, so two copies delivered concurrently are
both handled — one registration, two confirmation emails. So the charts pin one
replica, ship no HPA for the relay, and fail to render if anyone raises the count
(warning 1 shows the error). Chart, document and source now say the same thing,
and the guard is what stops a values file or a `--set` from leaving all three
behind.

Four other disagreements remain, and they are listed in full below, because "the
charts implement the spec except here" was the claim this file used to make and
it was not true.

**Before the guard can be lifted, in this order:**

1. Land `FOR UPDATE SKIP LOCKED` in
   `eventa-relay/src/relay/outbox-reader.repository.ts` so concurrent readers
   claim disjoint rows, and remove the warning at `eventa-relay/src/main.ts:15-20`.
2. Delete `deploy/charts/relay/templates/_guard.tpl` and the `singleton` block
   from `deploy/charts/relay/values.yaml` in the same change, so the chart and the
   code stop disagreeing at the same commit.
3. Only then raise `replicas` and add the outbox-lag HPA — which §3.2 sanctions
   for exactly that moment, not before: "the outbox-lag metric that §6 uses for
   *alerting* can additionally serve as a scaling signal" once the reader claims
   rows. Keep the PodDisruptionBudget at or above one publisher.

Step 3 without step 1 is the double-publish.

### Every place the charts do not do what a document says

Four, verified by rendering each chart rather than by reading its comments. Two
of them (3 and 4) are cases of the document being **wrong** — a grouping that
puts the relay with services whose needs it does not share, and a parenthetical
that is out of date for the worker. Two (1 and 2) are cases of a document asking
for something `eventa-relay` **cannot yet do**; those close when the service
gains the feature, not when the document is edited. None of them is a free
choice, and each is argued in the chart that makes it. Each row's "what the
document says" column was re-read against `eventa-docs` as it stands, not
carried over from the last time this table was written.

| # | Deviation | What the document says | Why the chart differs |
| --- | --- | --- | --- |
| 1 | **relay serves no `/metrics`** | `devops-observability-sre.md` §1: "all 5 workloads via `/metrics`" | `eventa-relay/src/main.ts:24` creates an application *context* — no `listen`, no controller, no port, so there is nothing to scrape. §2 anticipates this and sources outbox lag from a "relay gauge / **DB query exporter**", which is the better signal anyway because it still reports when the relay is gone. |
| 2 | **relay ships no probes** | §3.3: "Workers/relay use exec/TCP checks … plus broker-connection health"; `devops-ci-cd.md` §4.3: "every workload defines `startup`, `readiness`, `liveness`" | That is the right probe and `eventa-relay` does not have it: no health module, no CLI entrypoint, no second binary. TCP has nothing to connect to. With `maxSurge: 0`, an `exec` probe pointed at an absent command would leave **zero** publishers on every deploy. |
| 3 | **relay has no Redis egress** | §3.3 groups "api/checkin/worker/relay → Postgres/Redis/RabbitMQ" | `eventa-relay`'s env schema has no `REDIS_URL` and the service holds no cache, session or idempotency state (`src/config/env.validation.ts:11-27`). §3.3's own rule is that nothing undeclared is permitted. |
| 4 | **worker uses HTTP probes, not exec/TCP** | the same §3.3 sentence's "(no HTTP server)" | Out of date for the worker: `eventa-worker/src/main.ts:18` calls `app.listen(port)` and `src/health/health.controller.ts:27,36` serves `/health/live` and `/health/ready`, with liveness reporting "attached to the queue" — which is the broker-connection health the same sentence asks for. **The parenthetical is wrong.** |

One further place where the *documents disagree with each other* and the charts
follow the more specific one, which is a reading rather than a deviation — and
one where they agree, in wording that is easy to misread as a disagreement:

- **`web` has no startup probe.** §3.3 puts a startup probe "on api/worker";
  ci-cd §4.3 says every workload defines one. The charts follow §3.3, and web is
  a Node SSR server with no cold NestJS boot to cover.
- **UAT auto-syncs, and §7's "Gated promotion" is why that is right.** The gate
  §7 names is on the *promotion*, not on the Argo CD *sync* that follows it:
  ci-cd §4.1 gates UAT on a PO/QA approval of the tag bump, and §1.3 and §4.1
  reserve a gated sync for production alone.
  [argocd/README.md](argocd/README.md) works this through.

### `eventa-docs` needs two more corrections, and this repo cannot make them

This section used to list five, and asked for all five at once. **Three have
since been applied upstream** — `devops-infrastructure.md` §3.2's relay row,
§6's Pods and Consumers rows, and `devops-ci-cd.md` §0's relay row all now match
the charts, and §3.2 additionally documents this repo's render guard (warning 4
quotes the before and after). They are struck from the table rather than left on
it with a note: a list that keeps crying wolf on entries somebody already fixed
is a list the next reader stops checking, including on the two below, which are
real.

`eventa-docs` is read-only from here, so the remaining two need somebody with
write access. Both were re-read against the current text before being kept, and
every line number below was produced by this command rather than carried over —
re-run it before trusting the column, because `eventa-docs` is edited
independently of this repo and a line number is the first thing to rot:

```sh
cd ../eventa-docs
grep -n "all 5 workloads" 08-maintenance/devops-observability-sre.md
grep -n "api/checkin/worker/relay\|exec/TCP" 07-deployment/devops-infrastructure.md
```

| Document and entry | Should say | Verified still wrong |
| --- | --- | --- |
| `devops-observability-sre.md` §1, Metrics row | "all 5 workloads via `/metrics`" → four; the relay is measured by the DB query exporter §2 already names. | Still reads "all 5 workloads via `/metrics`, plus RabbitMQ, Postgres, Redis exporters" (§1, line 39). |
| `devops-infrastructure.md` §3.3, NetworkPolicy allows and probes bullet | Drop `relay` from the Redis grouping, and drop "(no HTTP server)" from the workers half of the probes sentence. | Still reads "api/checkin/worker/relay → Postgres/Redis/RabbitMQ" (line 264) and "Workers/relay use exec/TCP checks (no HTTP server) plus broker-connection health." (line 253). |

Until those two land, a reader of those sections will believe them and reopen a
settled question. The two charts that deviate carry their own entries in an
`eventa.io/spec-deviations` annotation — `deploy/charts/relay/Chart.yaml` has
items 1–3 plus this correction list, and `deploy/charts/worker/Chart.yaml` has
item 4 — so a deviation travels with the chart that makes it and not only with
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

Expect twenty `OK` lines and no `SKIP`: every chart has an overlay for every one
of §7's four parity environments, so all 20 service/environment pairs render
today. The `[ -f "$f" ]` guard is kept because a `SKIP` is the clearest possible
report of an overlay that has been deleted or renamed. Verified with helm 4.3.0.

**No chart deploys into an environment without that environment's overlay, and
that is deliberate.** The baseline `values.yaml` of each chart is the production
sizing from §3.3 with nothing environment-specific in it; the overlay supplies
the image tag, the secret path, the hostnames and the data-subnet CIDRs.
Rendering for an environment without one fails, rather than quietly deploying a
chart that has no secrets and an unpullable image.

**The namespace is load-bearing in that sentence, and `-n` is easy to drop.**
The checks that guard environment coordinates are gated on the namespace being
one of §7's four (`deploy/charts/api/templates/_validate.tpl:27`, `$isEnv`),
because
`values.yaml` deliberately holds no environment's Prometheus URL and a bare
baseline render is not a deploy. So `helm template api deploy/charts/api` with
no `-n` **succeeds** — 626 lines, exit 0 — and only the namespaced form refuses:

```sh
helm template api deploy/charts/api -n eventa-prod
# Error: execution error at (api/templates/workload.yaml:19:10): [api] canary.analysis has a Prometheus gate with no address. Set canary.analysis.prometheusAddress (per environment — devops-observability-sre.md §1 puts the metric sink in the `platform` namespace), or an address on the individual metric. An unreachable provider makes every measurement an error, and with failureLimit 0 that aborts every api deploy at the first step for a reason that has nothing to do with the build.
#
# Use --debug flag to render out invalid YAML
```

The other four refuse either way, because a values-schema failure does not
depend on the namespace. They do not all fail on the same thing, and the
difference matters when you are reading an error:

| Chart | `helm template <chart> deploy/charts/<chart> -n eventa-prod` fails on | …without `-n` |
| --- | --- | --- |
| `web`, `checkin`, `worker`, `relay` | the values schema, at `/image`: no usable `tag` and no `digest`. (`web`, `checkin` and `relay` have no `tag` key at all; `worker`'s is present and empty, so its message is a `minLength` failure rather than a missing property.) | same |
| `api` | its **templates** — `canary.analysis` has a Prometheus gate with no `prometheusAddress` | renders |

The api never reaches an image check at all, and not because `canary.analysis`
is validated first: schema validation runs *before* any template, and the api's
baseline passes it, because `deploy/charts/api/values.yaml:27` carries
`tag: sha-0000000` — a syntactically valid SHA tag kept there precisely so the
chart renders. What the overlay supplies for the api is the Prometheus address
(observability §1 puts the metric sink in `platform`, per environment). So a
missing overlay is always caught on a namespaced render, but "the image tag is
missing" is not a reliable thing to expect in the message.

Use the release name shown above — the **service** name, not a per-environment
one, because `web` reaches the api at `http://api/api/v1`.

**`kubectl apply --dry-run=client` does not work here.** Even "client" validation
downloads the OpenAPI schema from a live API server, so with no cluster it fails
on `connection refused` before validating anything —
`failed to download openapi: Get "http://localhost:8080/openapi/v2…"` — and
`--validate=false` only moves the failure to API-group discovery on
`http://localhost:8080/api`. Offline schema validation needs `kubeconform`,
which is not installed (`kubeconform not found`). Each chart's README records
this too.

## Local development

Local development runs the whole platform from
[`eventa-api/docker-compose.yml`](../eventa-api/docker-compose.yml) (Postgres,
RabbitMQ, Mailpit) plus the four services started by hand — see
[how-services-connect.md](../eventa-docs/04-architecture/how-services-connect.md).
Nothing in this repo is involved; the charts and the Argo CD manifests describe a
cluster that does not exist yet.

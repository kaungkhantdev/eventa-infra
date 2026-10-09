# `web` — the React SSR public site

The first of the five service charts in `devops-infrastructure.md` §1.2. It is
one line of template plus values: everything the five workloads share lives in
[`../_library`](../_library/README.md), and this chart states only what `web`
differs by.

**This chart implements a specification; it does not make design decisions.**
The sources of truth are
[`devops-infrastructure.md`](../../../../eventa-docs/07-deployment/devops-infrastructure.md)
(§1.2 Helm layout, §3.1 namespaces, §3.2 workloads, §3.3 resources/probes/
disruption/network, §5 config and secrets, §6 scaling, §7 environments, §8
FinOps) and
[`devops-ci-cd.md`](../../../../eventa-docs/07-deployment/devops-ci-cd.md)
(§3 immutable tags, §4.1 promotion, §4.2 rolling vs canary, §4.3 sync waves).
Every value in `values.yaml` cites the section it comes from, and the four
places this chart had to decide something the documents do not settle are
listed under [Open decisions](#open-decisions) rather than buried.

## What it renders

Eight objects, all from the library, verified for each of the four
environments:

| Object | Shape | Source |
| --- | --- | --- |
| Deployment | 1 container, rolling `maxSurge 1 / maxUnavailable 0`, soft zone anti-affinity, non-root with a read-only root filesystem and a writable `/tmp`, **no `replicas` field** | §3.3 |
| Service | ClusterIP, `80 → http` | §3.3 |
| Ingress | one host per environment, no class and no TLS — see below | §3.3, §2 |
| HorizontalPodAutoscaler | CPU + RPS, min 3 in prod | §3.2, §6 |
| PodDisruptionBudget | `minAvailable: 50%` | §3.3 |
| NetworkPolicy | ingress from `platform`; egress to DNS and **the api only** | §3.3 |
| ConfigMap | `PORT`, `LOG_LEVEL`, `API_BASE_URL`, hashed into the pod template | §5 |
| ServiceAccount | token not mounted | §5 |

No ExternalSecret (web holds no secret), no migration Job (`eventa-api` owns
every migration), and no namespace-wide default-deny NetworkPolicy (one release
per namespace owns that object, and `_library/README.md` puts it on the api).
`values.yaml` ends with the full list of what is inherited and from which
section, so silence there never has to mean nobody considered it.

The Deployment deliberately carries **no `replicas`**: the HPA owns that field,
and Argo CD runs with self-heal (§1.3), so a count in Git would be reverted
onto a workload the HPA had just scaled out for an on-sale burst.

## The NetworkPolicy is the point of this chart

`web` is reached by the ingress controller and talks to the **api**. It does not
touch the data tier. §3.3 lists the Postgres/Redis/RabbitMQ allows for
`api/checkin/worker/relay` and not for `web`, and §2 reaches the private data
subnets only from the app subnets through policy — so those three egress
toggles stay off, and an SSR page that later wants a query goes through the api
like every other reader. `egress.external` (Stripe, PromptPay, comms via NAT)
stays off too: web takes no payment and sends no mail.

Mechanically, the rule selects the **api pods**, not its Service — egress policy
is evaluated against the destination pod IP after the Service's DNAT — and
narrows on `app.kubernetes.io/component: api` so it excludes the check-in pool,
which runs the same image under the same name (§3.2).

> **This is half of the path, and the other half lives in the api chart.** A
> default-deny namespace requires the source's egress *and* the destination's
> ingress to allow the connection. For a while no chart in this repo set
> `networkPolicy.ingress.fromPods` at all, so web could send and the api would
> not receive — in every environment, with the Ingress, Service, Rollout and
> pods all reporting healthy. `api/values.yaml` now carries the matching entry,
> selecting `app.kubernetes.io/name: web` **and**
> `app.kubernetes.io/component: web` on 3000, in the baseline rather than an
> overlay so that every environment inherits it.
>
> Keep the two halves in the same change whenever either moves. §3.3's "no
> pod-to-pod that isn't declared" makes a *forgotten* declaration silent, which
> is the opposite of how the rest of this chart's mistakes behave: an undeclared
> egress CIDR is a render error, but an undeclared ingress peer is a connection
> that is simply dropped.

## Environments

`values.yaml` is the **production baseline** (§3.2's prod figures). Each overlay
states only what §7 lets an environment differ by, which is why three of them
are under 20 lines.

| Env | Namespace | Replicas (min/max) | Log level | Host |
| --- | --- | --- | --- | --- |
| dev | `eventa-dev` | 1 / 3 | `debug` | `dev.eventa.dev` |
| staging | `eventa-staging` | 2 / 20 | `info` | `staging.eventa.dev` |
| UAT | `eventa-uat` | 2 / 6 | `info` | `uat.eventa.dev` |
| prod | `eventa-prod` | **3** / 20 | `info` | *unset — see below* |

Only prod's floor of 3 is fixed by a document (§3.2). The rest follow §8's
"dev/staging/uat run smaller replica counts" and §6's requirement that every HPA
have a ceiling and never a floor of 0 for a prod service; staging keeps prod's
ceiling because §7 runs the perf checks there and a scale-out test against a
lower ceiling measures the ceiling. UAT is included although it was not asked
for: §3.1 and §7 define it as one of the four parity environments, and without
the file the chart cannot be deployed to `eventa-uat` at all.

`preview-<pr>` (§3.1, §7, `devops-ci-cd.md` §1.1) has no overlay here. Its
values — scale-to-zero when idle (§8), the per-PR namespace and the
`pr-<n>.preview.eventa.dev` hostname — are generated per pull request by the
Argo CD `ApplicationSet` that belongs in `eventa-infra/argocd/`, which does not
exist yet. Writing a static guess at them now would be designing.

## Before the first production sync

1. **Set the production hostname.** `values-prod.yaml` carries
   `www.eventa.invalid`. No document names the public hostname: §2 puts CDN →
   WAF → load balancer in front of this Ingress, so it is a DNS/edge decision
   owned by the Terraform `edge` and DNS modules (§1.1), neither of which has
   been written. `.invalid` is reserved by RFC 2606 and resolves nowhere, so a
   forgotten placeholder fails closed rather than quietly answering on a name
   somebody guessed.
2. **Confirm `API_BASE_URL`.** The global prefix `api/v1` is settled
   (`eventa-api/src/main.ts:18`); the host is the api release's Service name,
   which the Argo CD Application fixes.
3. **Add the workload-identity annotation** to `serviceAccount.annotations` if
   and when web gains a secret — the commented block in `values-prod.yaml` says
   why the key cannot be written here.

## Open decisions

Four things the documents do not settle, resolved here and flagged so the next
person can disagree with the reasoning rather than guess at it:

| Thing | What this chart does | Why |
| --- | --- | --- |
| The RPS metric name | `http_requests_per_second`, a `Pods` metric | §3.2 names the signal; the series name belongs to whichever Prometheus adapter an environment runs and §6 names none, which is why `../_library` ships no metric names at all. Shipping CPU alone would look complete and silently be half the policy. Until an adapter exposes the series the HPA records `FailedGetPodsMetric` and keeps scaling on CPU — the controller only gives up when *every* metric is unavailable — so the gap is visible and one line wide. |
| The RPS target (50/pod) and ceiling (20) | Starting points | §3.3 calls even its own CPU/memory figures "starting points, tuned from Prometheus" and §6 makes that a standing loop. Retune from the per-workload golden-signals dashboard (`devops-observability-sre.md` §1.2). |
| The prod hostname | `www.eventa.invalid`, fails closed | See above. The non-prod hosts extrapolate from `pr-<n>.preview.eventa.dev` (`devops-ci-cd.md` §1.1), the only domain any document names; the product's own domain is not derivable from it. |
| `ingress.className`, `annotations`, `tls` | Unset | All three name a specific ingress controller, and §3.1 says only that the controller runs in `platform`. An Ingress with no class is admitted by the cluster's default IngressClass, and §2 terminates TLS at the edge/load balancer, so there is no certificate for this object to reference. |

Also worth knowing: the rendered NetworkPolicy has **two ingress rules that
differ only in a placeholder** — one for the ingress controller, one for the
metrics scraper, both in `platform` (§3.1) on the http port. §3.1 names neither
product, so the library ships each with a `podSelector` of
`app.kubernetes.io/name: REPLACE-ME-ingress-controller` and
`REPLACE-ME-metrics-scraper`: the right shape with a deliberately wrong value.
A namespace-only peer was not an option — `platform` also holds Argo CD and
External Secrets, so it would let the Argo CD repo-server open a connection
straight to web, and `_library/templates/_validate.tpl` refuses that form.

**Both placeholders fail closed.** No pod carries either label, so until they are
replaced this workload takes no inbound traffic at all, including the Prometheus
scrape. That is the safe direction for a policy and it is visible — the marker
string appears verbatim in the rendered object and in an Argo CD diff — but it
does mean these two values have to be set before the first real sync, and they
are not Terraform outputs like the rest of this chart's placeholders.

## Verifying a change

```sh
cd deploy/charts/web
helm dependency update .          # resolves file://../_library into charts/
helm lint .
for env in dev staging uat prod; do
  helm template web . -n "eventa-$env" -f "values-$env.yaml" >/dev/null || echo "$env FAILED"
done
```

`kubectl apply --dry-run=client` is **not** a usable check in this repo: it
resolves every `kind` through API discovery and downloads the OpenAPI schema
from a live API server, so with no cluster it fails on `connection refused`
before validating anything (`--validate=false` fails the same way, on
`/api`). A server-side pass needs either a cluster or an offline validator with
bundled schemas (`kubeconform`), neither of which is available here yet. Until
one is, `helm lint` plus `helm template` for all four environments is the gate,
and `_library/templates/_validate.tpl` catches at render time most of what the
API server would have caught at apply time — including a moving image tag, a
credential in `config.env`, a liveness probe pointed at the readiness endpoint,
and a data-store egress rule with no CIDR.

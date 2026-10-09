{{/*
api-specific contract checks, on top of the 18 the library already runs.

Everything here is a failure that a cluster accepts and then gets wrong: a
Rollout nothing reconciles, an HPA pointed at a Deployment this chart does not
render, a probe 404ing against the wrong URL prefix, a canary gate that says yes
unconditionally, migrations moved back into app startup. None of it is style —
each check is a thing that would deploy and look healthy.

Called with (dict "v" <merged values> "ctx" <root context>) from `api.values`,
so it runs on every template this chart renders.
*/}}
{{- define "api.validate" -}}
{{- $v := .v -}}
{{- $ctx := .ctx -}}
{{- $ns := $ctx.Release.Namespace -}}

{{- /*
  Whether this release is going into one of the real environments
  (devops-infrastructure.md §3.1). `helm lint` and a bare `helm template` land
  in `default`, where the environment-coupled checks below have nothing to
  check: the CIDRs, hostnames and secret paths they look for are exactly what
  values-<env>.yaml carries. Rendering for a named environment without that
  file is the mistake worth catching.
*/ -}}
{{- $envNamespaces := list "eventa-dev" "eventa-staging" "eventa-uat" "eventa-prod" -}}
{{- $isEnv := or (has $ns $envNamespaces) (hasPrefix "preview-" $ns) -}}
{{- $isProd := eq $ns "eventa-prod" -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Identity                                                           */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if ne $v.component "api" -}}
{{- fail (printf "[api] component is %q. This chart is the core api Deployment (devops-infrastructure.md §3.2); the dedicated check-in pool runs the same image from its own chart with component `checkin`, which is what keeps a door-scanning surge off the checkout pool. Deploying the check-in pool from this chart would give both pools the same canary, the same HPA and the same pod selector." $v.component) -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* The URL prefix the api actually serves on                          */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  eventa-api/src/main.ts:18 calls `app.setGlobalPrefix('api/v1')`, so every
  route — the health probes and the Prometheus endpoint included — is mounted
  under /api/v1. devops-infrastructure.md §3.3 writes the endpoints as
  `/health/ready` and `/health/live` because it is describing the contract, not
  this service's routing table.

  Getting this wrong is quiet in the worst way. A readiness probe on
  /health/ready gets a 404, the pod never becomes ready, and the canary stalls
  at 10% with pods that are running and serving traffic fine on the real path. A
  /metrics scrape on the wrong path returns 404 and the outbox-lag gauge — the
  one signal eventa-infra/README.md says actually matters — is simply absent,
  with nothing anywhere reporting an error.
*/ -}}
{{- $prefix := "/api/v1" -}}
{{- range $probe := list "readiness" "liveness" "startup" -}}
{{- $cfg := index $v.probes $probe -}}
{{- if and $cfg.enabled (eq $cfg.type "http") -}}
{{- if not (hasPrefix $prefix $cfg.http.path) -}}
{{- fail (printf "[api] probes.%s.http.path is %q, which the api does not serve. eventa-api/src/main.ts:18 sets a global prefix of `api/v1`, so the endpoint is %s%s. A readiness probe on the unprefixed path 404s forever: the pod never goes ready, the canary never advances past its first step, and the pods are meanwhile answering requests correctly on the real path." $probe $cfg.http.path $prefix $cfg.http.path) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $v.metrics.enabled (not (hasPrefix $prefix $v.metrics.path)) -}}
{{- fail (printf "[api] metrics.path is %q. eventa-api mounts the scrape endpoint under its global prefix (eventa-api/src/modules/metrics/metrics.controller.ts behind main.ts:18), so it is %s/metrics. A 404 here loses eventa_outbox_lag_seconds, which is the signal eventa-infra/README.md and devops-observability-sre.md §2 both say to alert on — and it loses it silently, because a scrape of a 404 is not an error anybody is watching." $v.metrics.path $prefix) -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Exactly one workload object                                        */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if and $v.rollout.enabled $v.deployment.enabled -}}
{{- fail (printf "[api] rollout.enabled and deployment.enabled are both true, which renders a Rollout and a Deployment with the same pod selector (%s). Two controllers would fight over the same pods: each sees the other's replicas as its own surplus and deletes them. devops-ci-cd.md §4.2 gives the api a canary, so leave deployment.enabled false." (include "eventa-library.fullname" $ctx)) -}}
{{- end -}}
{{- if and (not $v.rollout.enabled) (not $v.deployment.enabled) -}}
{{- fail "[api] neither rollout.enabled nor deployment.enabled is set, so this chart renders a Service, an HPA and a PDB with no pods behind them. The Service would answer with connection refused and the HPA would report <unknown> — set rollout.enabled (the specified strategy, devops-ci-cd.md §4.2) or deployment.enabled (a plain rolling update, for a cluster with no Argo Rollouts controller)." -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* The HPA has to point at whichever object exists                    */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  An HPA whose scaleTargetRef names an object that does not exist is not an
  error to Kubernetes: the HPA is created, reports `FailedGetScale`, and scales
  nothing. The api would then sit at its floor through an on-sale burst, which
  is the one moment §6's autoscaling exists for.
*/ -}}
{{- if $v.hpa.enabled -}}
{{- $kind := $v.hpa.scaleTargetRef.kind | default "Deployment" -}}
{{- if and $v.rollout.enabled (ne $kind "Rollout") -}}
{{- fail (printf "[api] hpa.scaleTargetRef.kind is %q but this chart renders a Rollout, not a Deployment (devops-ci-cd.md §4.2). The HPA would be created, report FailedGetScale against an object that does not exist, and scale nothing — so the api would stay at its floor through exactly the on-sale burst devops-infrastructure.md §6 scales for. Set hpa.scaleTargetRef.kind to Rollout and apiVersion to argoproj.io/v1alpha1." $kind) -}}
{{- end -}}
{{- if and (not $v.rollout.enabled) (eq $kind "Rollout") -}}
{{- fail "[api] hpa.scaleTargetRef.kind is Rollout but rollout.enabled is false, so no Rollout is rendered for the HPA to scale." -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Migrations: gated Job, never app startup                           */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  devops-ci-cd.md §5.1 and devops-infrastructure.md §3.3: migrations are a
  gated pre-deploy Job and never run inside app startup. eventa-api owns every
  migration (eventa-infra/README.md), while worker and relay keep typed mirrors
  of the tables they touch — so this chart is the only one that may carry the
  Job, and it is the only one whose absence would mean nothing migrates at all.
*/ -}}
{{- if and $isEnv (not $v.migrationJob.enabled) -}}
{{- fail (printf "[api] migrationJob.enabled is false while deploying to %s. eventa-api owns every migration (eventa-infra/README.md), and devops-ci-cd.md §5.1 runs them as a PreSync Job in sync wave 1 so that new pods never start against an un-migrated schema. With the Job off, the api rolls first and fails on its first query against a table that does not exist yet — and worker and relay, whose typed mirrors fail on write rather than on read (§5.3), fail later and in production." $ns) -}}
{{- end -}}
{{- if and $v.migrationJob.enabled (not $v.migrationJob.command) (not $v.migrationJob.args) -}}
{{- fail "[api] migrationJob.enabled is true but neither command nor args is set, so the Job runs the image's default entrypoint — which starts the API server. A long-running server as a PreSync hook never exits 0, so Argo CD waits on it and the sync hangs instead of deploying. eventa-api's migration entry point is the `migrate` script in its package.json." -}}
{{- end -}}
{{- /*
  The other half of "never inside app startup": a chart that enables the Job and
  ALSO sets a boot-time migration flag on the long-running pods gets two
  migrators, one of which runs once per replica during a canary — concurrently,
  on the same schema, from pods of two different revisions.
*/ -}}
{{- range $key, $_ := ($v.config.env | default dict) -}}
{{- $upper := upper (toString $key) -}}
{{- if or (contains "MIGRAT" $upper) (contains "SYNCHRONIZE" $upper) -}}
{{- fail (printf "[api] config.env.%s puts a migration switch on the long-running pods. devops-ci-cd.md §5.1 and devops-infrastructure.md §3.3 are explicit that schema changes run as a gated pre-deploy Job and NEVER inside app startup: a boot-time migration runs once per replica, so a canary at 10%% runs it from the new revision while the stable revision is still serving — two migrators on one schema, ordered by whichever pod won. A knob the migration Job itself needs goes in migrationJob.extraEnv, which only the Job sees." $key) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Argo CD sync wave (devops-ci-cd.md §4.3)                           */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if ne (toString $v.argocd.syncWave) "2" -}}
{{- fail (printf "[api] argocd.syncWave is %q; devops-ci-cd.md §4.3 fixes the order as (1) migration pre-deploy job → (2) api/worker/relay → (3) web. Without wave 2 on this chart's objects, Argo CD may sync the api alongside web, or ahead of the Job's wave — and §5.3's ordering rule (expand migrations land before the services whose event shapes depend on them) is the whole reason the waves exist." (toString $v.argocd.syncWave)) -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Canary steps (devops-ci-cd.md §4.2)                                */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if $v.rollout.enabled -}}
{{- if not $v.canary.steps -}}
{{- fail "[api] canary.steps is empty, which makes the Rollout promote the new revision to 100% in one move. That is a rolling update wearing a Rollout's name, and it removes the small-slice exposure devops-ci-cd.md §4.2 gives the api because it is the checkout and payments surface." -}}
{{- end -}}
{{- $previous := 0 -}}
{{- range $weight := $v.canary.steps -}}
{{- if or (le (int $weight) 0) (ge (int $weight) 100) -}}
{{- fail (printf "[api] canary.steps contains %v. A step is a weight strictly between 0 and 100: 100 is not a step but the Rollout completing, and a 0 step pauses with no canary pods to measure. §4.2's sequence is 10 → 25 → 50 → 100, so the steps are 10, 25, 50." $weight) -}}
{{- end -}}
{{- if le (int $weight) $previous -}}
{{- fail (printf "[api] canary.steps is not increasing (%d after %d). Each step exposes a larger slice than the last; a step that goes backwards would shrink the canary after a passing gate and measure the next gate on fewer pods than the one before it." (int $weight) $previous) -}}
{{- end -}}
{{- $previous = int $weight -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Canary analysis                                                    */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if and $v.rollout.enabled $v.canary.analysis.enabled -}}
{{- if not $v.canary.analysis.metrics -}}
{{- fail "[api] canary.analysis.enabled is true with no metrics. An AnalysisTemplate with an empty metrics list succeeds unconditionally — every step passes, the dashboard says the api is canary-gated, and nothing is measured. devops-ci-cd.md §4.2 lists the gates: 5xx rate, p95 latency on checkout endpoints, pod readiness/crashloops, Sentry new-error rate, synthetic checkout probe." -}}
{{- end -}}
{{- /*
  The address is an environment coordinate like the CIDRs and the secret path,
  so it is checked when rendering for an environment rather than on the bare
  baseline — values.yaml deliberately holds no environment's Prometheus URL.
*/ -}}
{{- if and $isEnv (not $v.canary.analysis.prometheusAddress) -}}
{{- $needsProm := false -}}
{{- range $m := $v.canary.analysis.metrics -}}
{{- if hasKey ($m.provider | default dict) "prometheus" -}}
{{- if not (dig "prometheus" "address" "" ($m.provider | default dict)) -}}
{{- $needsProm = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $needsProm -}}
{{- fail "[api] canary.analysis has a Prometheus gate with no address. Set canary.analysis.prometheusAddress (per environment — devops-observability-sre.md §1 puts the metric sink in the `platform` namespace), or an address on the individual metric. An unreachable provider makes every measurement an error, and with failureLimit 0 that aborts every api deploy at the first step for a reason that has nothing to do with the build." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $isProd (not $v.canary.analysis.enabled) -}}
{{- fail "[api] canary.analysis.enabled is false for eventa-prod. The steps would then advance on a timer, which exposes 100% of checkout traffic to an unmeasured build — devops-ci-cd.md §4.2 requires analysis at each step precisely because this is the payments surface, and §8.1's automated rollback is the analysis aborting." -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Per-environment coupling (devops-infrastructure.md §3.1, §3.3, §5) */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if $isEnv -}}
{{- if not $v.externalSecret.enabled -}}
{{- fail (printf "[api] externalSecret.enabled is false while deploying to %s. The api needs DATABASE_URL and JWT_SECRET to boot at all (eventa-api/src/config/env.validation.ts requires both with no default), and devops-infrastructure.md §5 says the only path a secret takes into a pod is the External Secrets Operator reading /eventa/<env>/*. A literal in values would be the one thing §5 forbids." $ns) -}}
{{- end -}}
{{- /*
  The api talks to Postgres, Redis and RabbitMQ (§3.3). In the four long-lived
  environments those are managed services in private data subnets (§2), so the
  allow is an ipBlock from the Terraform network module. In a PR preview they
  are throwaway pods in the preview namespace (devops-ci-cd.md §1.1), so the
  allow is a pod selector instead. Either is fine; neither is not, because a
  default-deny namespace with no data-store egress gives an api whose readiness
  probe fails on its first `select 1` and a rollout that never leaves step one.
*/ -}}
{{- $eg := $v.networkPolicy.egress -}}
{{- $cidrStores := and $eg.postgres.enabled $eg.redis.enabled $eg.rabbitmq.enabled -}}
{{- if and $v.networkPolicy.enabled (not $cidrStores) (not $eg.toPods) -}}
{{- fail (printf "[api] no data-store egress is declared for %s. devops-infrastructure.md §3.3 allows api → Postgres/Redis/RabbitMQ explicitly on top of a default-deny namespace; with neither the managed-service CIDRs (networkPolicy.egress.{postgres,redis,rabbitmq}, from the Terraform network module output for this environment) nor pod selectors for a preview's own ephemeral stores (networkPolicy.egress.toPods, devops-ci-cd.md §1.1), the readiness probe fails on its first `select 1` and the canary stalls at step one with healthy-looking pods." $ns) -}}
{{- end -}}
{{- if not $v.ingress.enabled -}}
{{- fail (printf "[api] ingress.enabled is false while deploying to %s. devops-infrastructure.md §3.3 routes ingress to web/api/checkin, and every environment in §7 has its own host — down to pr-<n>.preview.eventa.dev for a preview (devops-ci-cd.md §1.1). Without an Ingress the api is reachable only from inside the cluster, so the web SSR pods would work and every browser request to the api would not." $ns) -}}
{{- end -}}
{{- if and $v.networkPolicy.enabled (not $v.networkPolicy.ingress.fromIngressController.enabled) -}}
{{- fail (printf "[api] networkPolicy.ingress.fromIngressController is disabled for %s. §3.3 allows ingress → web/api/checkin, and the controller runs in `platform` (§3.1); without the allow, the default-deny policy drops every request at the api's pods while the Ingress, the Service and the pods all report healthy." $ns) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Production floor (devops-infrastructure.md §3.2, §6)               */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if $isProd -}}
{{- if not $v.hpa.enabled -}}
{{- fail "[api] hpa.enabled is false for eventa-prod. devops-infrastructure.md §3.2 scales the api on CPU + RPS + p95 latency, and §6 calls the on-sale burst the load this platform is shaped around — a fixed replica count meets it by queueing." -}}
{{- end -}}
{{- if lt (int $v.hpa.minReplicas) 3 -}}
{{- fail (printf "[api] hpa.minReplicas is %d for eventa-prod; devops-infrastructure.md §3.2 sets the api's prod minimum at 3. Below three, the 50%% PodDisruptionBudget (§3.3) allows a node drain to take the api to one replica, and a canary step at 10%% has no pod to put the canary on without displacing a stable one." (int $v.hpa.minReplicas)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Guards specific to the check-in pool.

The library's `_validate.tpl` enforces the contract every workload shares. These
five checks enforce what is only true of THIS chart, and they exist because
`checkin` is the api chart's twin: it runs the same image, in the same
namespace, from a directory sitting next to four sibling charts that are the
obvious place to copy a block of values from. Each of the five mistakes is one
copy-paste or one convenience away from happening, and each of them fails in
production rather than in CI, because the manifests apply cleanly in all five
cases.

eventa-infra/README.md asks the charts to "make this hard to get wrong, not just
documented", so these fail the render: `helm template` catches them on a laptop,
in CI, and in an Argo CD diff, before a cluster accepts anything.

Two of them — the ingress-without-a-host check and the component check — are
generic enough to belong in `_library/templates/_validate.tpl` once a second
chart wants them. They are here rather than there because the library is shared
and this chart is the only evidence so far that they are needed.

The singleton check deliberately runs first, against the chart's raw values,
before anything touches `eventa-library.values`. The library's own singleton
guard would otherwise report first and explain the relay's problem, when what
the reader needs to know is why a singleton is wrong for THIS workload.
*/}}
{{- define "checkin.guards" -}}
{{- $raw := fromYaml (toYaml .Values) -}}
{{- if dig "singleton" "enabled" false $raw -}}
{{- fail (include "checkin.guard.singletonMessage" .) -}}
{{- end -}}

{{- $v := fromYaml (include "eventa-library.values" .) -}}

{{- if $v.migrationJob.enabled -}}
{{- fail (include "checkin.guard.migrationMessage" (dict "job" (printf "%s-migrate" (include "eventa-library.fullname" .)) "namespace" .Release.Namespace)) -}}
{{- end -}}

{{- if ne $v.component "checkin" -}}
{{- fail (include "checkin.guard.componentMessage" (dict "component" $v.component)) -}}
{{- end -}}

{{- if not $v.deployment.enabled -}}
{{- fail (include "checkin.guard.deploymentMessage" .) -}}
{{- end -}}

{{- if and $v.ingress.enabled (not $v.ingress.hosts) -}}
{{- fail (include "checkin.guard.ingressMessage" .) -}}
{{- end -}}
{{- end -}}


{{/*
The messages, kept out of the logic so each can say the whole thing: what
broke, why the rule exists, and what the manifest would have done if it had
rendered.
*/}}

{{- define "checkin.guard.migrationMessage" -}}
[checkin] migrationJob.enabled is true. Refusing to render.

The check-in pool must never run migrations. eventa-api owns every migration
(eventa-infra/README.md, third warning) and the api chart owns the Job —
devops-ci-cd.md §5.1 specifies ONE: an Argo CD `PreSync` hook in sync wave 1,
whose non-zero exit halts the sync.

Enabling it here produces a second one, `Job/{{ .job }}` in namespace
`{{ .namespace }}`, alongside the api release's own. The two land in the same
PreSync phase of the same wave, run the same `drizzle-kit migrate` from the
same image (eventa-api/package.json), and start at the same moment against the
same database.

§5.1's idempotency guarantee does not cover that. Re-running a migration is a
no-op because it is recorded in the migrations ledger — AFTER it has been
applied. Two Jobs that start together both read the ledger before either has
written to it, so both decide the same migration is pending and both run its
DDL. What that costs depends on the statement: a duplicate `CREATE INDEX`
fails and takes the deploy down with it, while a duplicate data backfill
succeeds twice and leaves rows nothing will flag.

It is also the hazard this chart's separation exists to remove. The pool is
separate so that a door-scan surge cannot disturb checkout
(devops-infrastructure.md §3.2); a migration Job attached to it puts the pool
back on the critical path of every api deploy.

If a migration ever has to be gated on something about this pool, gate it in
the api chart, which already owns the wave-1 hook.
{{- end -}}

{{- define "checkin.guard.componentMessage" -}}
[checkin] values.component is {{ .component | quote }}. Refusing to render.

This chart only works as "checkin". The pool and the main api pool run the SAME
image in the SAME namespace (devops-infrastructure.md §3.2), so
`app.kubernetes.io/component` is the only label that tells them apart — and the
library puts it in the Deployment's selector and in the Service's and the
PodDisruptionBudget's (`_library/templates/_helpers.tpl`,
`eventa-library.podSelectorLabels`).

Setting it to {{ .component | quote }} is therefore not a relabelling. This
release's Service starts load-balancing door scans onto the api pool's pods,
its PodDisruptionBudget starts counting the api's replicas as its own, and the
isolation §3.2 exists to provide is gone — while every manifest still applies
cleanly and a dashboard still shows two Deployments.
{{- end -}}

{{- define "checkin.guard.singletonMessage" -}}
[checkin] singleton.enabled is true. Refusing to render.

That setting belongs to the `relay` chart and to nothing else. The relay is
pinned to one replica because its outbox reader takes no row lock
(eventa-relay/src/relay/outbox-reader.repository.ts:25, and
eventa-relay/src/main.ts:20 states the precondition), so a second replica
publishes every message twice.

Nothing about the check-in pool has that constraint, and the guard does three
things that are each the opposite of what this workload is for: it writes
`replicas: 1` as a literal that no values file can raise, it refuses to render
the HorizontalPodAutoscaler, and it forces `maxSurge: 0`. A door-scan surge
would then be served by a single pod with no autoscaler — which is the failure
devops-infrastructure.md §3.2 and §6 separated this pool out to prevent.
{{- end -}}

{{- define "checkin.guard.deploymentMessage" -}}
[checkin] deployment.enabled is false. Refusing to render.

That is the api chart's setting, not this one's. The api sets it false because
it is canary-deployed with Argo Rollouts and renders its own Rollout around
`eventa-library.podTemplate` (devops-ci-cd.md §4.2). The same section gives the
check-in pool "Rolling (surge-friendly)" instead, and this chart renders no
workload object of its own.

With it false the release applies a Service, an HPA and a PodDisruptionBudget
with no pods behind any of them. The Service answers connection refused at the
door, and the HPA reports a missing scale target — neither of which is an error
anybody is paged for.
{{- end -}}

{{- define "checkin.guard.ingressMessage" -}}
[checkin] ingress.enabled is true but ingress.hosts is empty. Refusing to render.

The Ingress would render with no rules at all. That object applies without
complaint and routes nothing, so the door receives a 404 from the ingress
controller's default backend — which reads as an application fault rather than
as a missing hostname.

The hostname is per-environment (devops-infrastructure.md §7), so it belongs in
this release's values-<env>.yaml.
{{- end -}}

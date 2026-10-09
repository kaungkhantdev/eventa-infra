{{/*
The api chart's own values, on top of the library's contract.

The library owns everything the five workloads share; the only keys defined here
are the ones that exist because the api is canary-deployed (devops-ci-cd.md
§4.2) and nothing else is. They are kept in the same form the library uses — a
commented YAML document merged over the parent's values — so there is one place
to read the contract from and one place a default is stated.

`api.values` is what every template in this chart starts from. It returns the
library's merged, validated values with these defaults filled in underneath, so
a template can read `$v.resources` (library) and `$v.canary` (this chart) from
the same map.
*/}}
{{- define "api.defaults" -}}
# ---------------------------------------------------------------------------
# Argo Rollout (devops-ci-cd.md §4.2)
# ---------------------------------------------------------------------------
# The api is the one workload of the five that does not roll. §4.2: "Canary
# (Argo Rollouts): 10% → 25% → 50% → 100%, analysis at each step … Guards
# checkout/payment paths; catch regressions on a small slice."
#
# Setting `rollout.enabled: false` together with the library's
# `deployment.enabled: true` degrades this chart to a rolling Deployment. That
# is deliberately possible — a cluster without the Argo Rollouts controller
# would otherwise render a Rollout that nothing reconciles, which looks deployed
# and never starts a pod — but it is not the specified strategy, so
# `_validate.tpl` refuses the combination that renders neither and the one that
# renders both.
rollout:
  enabled: true

  # The surge the canary's own ReplicaSet is allowed while a step is scaling.
  # devops-infrastructure.md §3.3's rolling defaults (maxSurge 1,
  # maxUnavailable 0) apply to the pod churn inside a step: capacity never dips
  # below the desired count part-way through a canary.
  maxSurge: 1
  maxUnavailable: 0

  # How long the previous stable ReplicaSet stays scaled up after a promotion,
  # and after an abort. §8.1 wants the previous stable ReplicaSet pinned and
  # ready: a rollback that has to pull an image and cold-boot NestJS is a
  # rollback measured in minutes, and MTTR is a tracked DORA metric
  # (devops-observability-sre.md). Keeping it warm for half a minute makes an
  # abort a traffic shift rather than a deploy.
  scaleDownDelaySeconds: 30
  abortScaleDownDelaySeconds: 30

  # Weighted traffic routing (SMI / Istio / an ingress provider) is NOT set
  # here. §4.2 states the canary percentages but no document chooses a service
  # mesh or an ingress controller, and a `trafficRouting` block naming one would
  # bake that choice into the chart. Without it, Argo Rollouts implements the
  # weight by replica count — 10% of the pods run the new revision behind the
  # same Service — which needs no mesh and no CNI decision. Set this (and
  # canaryService / stableService) once a provider exists and the weights become
  # exact rather than proportional to replicas.
  trafficRouting: {}
  canaryService: ""
  stableService: ""

  annotations: {}
  labels: {}

# ---------------------------------------------------------------------------
# Canary steps and analysis (devops-ci-cd.md §4.2)
# ---------------------------------------------------------------------------
canary:
  # §4.2: 10% → 25% → 50% → 100%. The 100% is the rollout completing, so it is
  # not a step: after the last listed weight passes its analysis the Rollout
  # promotes the canary ReplicaSet to the full replica count. From there on §8.1
  # applies instead — a regression found at 100% is reverted by moving the image
  # digest back in Git, not by aborting a rollout that already finished.
  steps:
    - 10
    - 25
    - 50

  analysis:
    # §4.2: "automated AnalysisTemplate queries Prometheus at each step; the
    # step must satisfy all gates before advancing, else the rollout aborts and
    # rolls back".
    enabled: true

    # One measurement a minute for five minutes per step. The five minutes is
    # not arbitrary: devops-observability-sre.md §3 uses 5m as the fast burn-rate
    # window, so it is the shortest window the platform's own alerting trusts to
    # say anything about an SLO. A shorter window on a quiet environment
    # measures noise and aborts healthy rollouts.
    interval: 1m
    count: 5

    # Abort on the first failed measurement (§4.2: "else the rollout aborts and
    # rolls back"). A failureLimit above 0 means "this gate may fail once" —
    # which for the 5xx gate on the checkout path is a decision nobody made.
    failureLimit: 0

    # An inconclusive measurement is a gate that could not be evaluated, most
    # often because the series does not exist. It must not read as a pass, and
    # it must not read as a regression either: 0 here pauses the Rollout for a
    # human instead of aborting a deploy that may be fine.
    inconclusiveLimit: 0

    # The Prometheus the analysis queries. Per environment
    # (devops-observability-sre.md §1 puts the metric sink in `platform`), so it
    # comes from values-<env>.yaml; `_validate.tpl` refuses to render an
    # analysis with no address, because an unreachable provider makes every
    # measurement an error and every api deploy stall at 10%.
    prometheusAddress: ""

    # Passed to the AnalysisTemplate verbatim. The two hashes are how a query
    # tells the new revision's pods from the old one's: Argo Rollouts resolves
    # `podTemplateHashValue` at run time and labels every pod it creates with
    # `rollouts-pod-template-hash`.
    args: []

    # The gates themselves, passed through to the AnalysisTemplate verbatim —
    # the same idiom the library uses for `hpa.metrics`, and for the same
    # reason. §4.2 fixes the thresholds; the PromQL that measures them depends
    # on series names that belong to the scrape config of whichever Prometheus
    # an environment runs, and no document names them. Keeping the full query in
    # values means the operator reads and edits the exact expression that gates
    # their deploy, instead of reverse-engineering it out of a template.
    #
    # `_validate.tpl` refuses an enabled analysis with an empty list: an
    # AnalysisTemplate with no metrics succeeds unconditionally, which is a gate
    # that always says yes while the dashboard says the api is canary-gated.
    metrics: []
{{- end -}}

{{/*
The effective values for this chart: the library's merged and validated values,
with this chart's defaults underneath.

`mergeOverwrite dst src` lets src win, so the library-merged map (which already
contains the user's values.yaml and values-<env>.yaml) is the source and these
defaults are the destination.
*/}}
{{- define "api.values" -}}
{{- $apiDefaults := fromYaml (include "api.defaults" .) -}}
{{- $library := fromYaml (include "eventa-library.values" .) -}}
{{- $merged := mergeOverwrite $apiDefaults $library -}}
{{- $_ := include "api.validate" (dict "v" $merged "ctx" .) -}}
{{- $merged | toYaml -}}
{{- end -}}

{{/* The AnalysisTemplate this chart renders, and the Rollout steps reference. */}}
{{- define "api.analysisTemplateName" -}}
{{- printf "%s-canary" (include "eventa-library.fullname" .) -}}
{{- end -}}

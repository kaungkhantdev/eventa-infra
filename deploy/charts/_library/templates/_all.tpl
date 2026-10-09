{{/*
The single entry point, so a service chart is one line.

    # deploy/charts/relay/templates/workload.yaml
    {{- include "eventa-library.workload" . }}

Each object renders only if its own `enabled` flag says so, so the five charts
differ in values and not in template files — which is the point of §1.2's shared
library: a change to a probe or a disruption budget happens once, here.

A chart that needs something this list does not emit — the api's Argo Rollout,
for instance (devops-ci-cd.md §4.2) — includes the individual templates it wants
instead, and `eventa-library.podTemplate` gives it the same pod spec the other
four get.
*/}}
{{- define "eventa-library.workload" -}}
{{- $root := . -}}
{{- $templates := list
    "eventa-library.serviceaccount"
    "eventa-library.configmap"
    "eventa-library.externalsecret"
    "eventa-library.migrationJob"
    "eventa-library.deployment"
    "eventa-library.service"
    "eventa-library.ingress"
    "eventa-library.hpa"
    "eventa-library.pdb"
    "eventa-library.networkpolicy.defaultDeny"
    "eventa-library.networkpolicy"
-}}
{{- range $name := $templates -}}
{{- $rendered := include $name $root -}}
{{- if trim $rendered }}
---
{{ trim $rendered }}
{{- end -}}
{{- end -}}
{{- end -}}

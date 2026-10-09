{{/*
Names, labels and the merged-values accessor every other template starts from.

Every helper here takes the parent chart's ROOT context (`.`) and re-derives the
merged values itself, so a service chart never has to thread state through an
include. The merge is cheap and the alternative — passing a dict everywhere —
makes the consumer charts read worse.
*/}}

{{/*
The effective values: this library's defaults, with the parent chart's values
merged over them, validated.

`mergeOverwrite` deep-merges and does override with zero values, so a chart can
turn a defaulted `true` back off and blank a defaulted string. Lists are
replaced wholesale rather than appended, which is what a list of network allows
or HPA metrics wants.
*/}}
{{- define "eventa-library.values" -}}
{{- $defaults := fromYaml (include "eventa-library.defaults" .) -}}
{{- $merged := mergeOverwrite $defaults (deepCopy .Values) -}}
{{- /* Discard the output: validation either produces nothing or aborts. */ -}}
{{- $_ := include "eventa-library.validate" (dict "v" $merged "ctx" .) -}}
{{- $merged | toYaml -}}
{{- end -}}

{{/* The workload name: web | api | worker | relay | checkin. */}}
{{- define "eventa-library.name" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- default .Chart.Name $v.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The resource name. Release-scoped, because `api` and `checkin` run the same
image in the same namespace and a shared name would collide; and because the
preview environments (devops-infrastructure.md §3.1, §7) put one release per PR
into its own namespace with the same chart.
*/}}
{{- define "eventa-library.fullname" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.fullnameOverride -}}
{{- $v.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name $v.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "eventa-library.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The version label.

An image reference is not a valid label value: a digest contains a colon and a
tag can exceed 63 characters, both of which Kubernetes rejects outright — so the
reference is sanitised here rather than interpolated raw and discovered at apply
time.
*/}}
{{- define "eventa-library.versionLabel" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- $raw := $v.image.digest | default $v.image.tag | default .Chart.AppVersion | default "" -}}
{{- /*
  `regexReplaceAll` takes (regex, input, replacement), so it cannot be used in a
  pipeline here — piping would pass the replacement as the input and silently
  return the replacement string.
*/ -}}
{{- $clean := regexReplaceAll "[^A-Za-z0-9._-]" (toString $raw) "-" -}}
{{- $clean | trunc 63 | trimSuffix "-" | trimSuffix "." | trimSuffix "_" -}}
{{- end -}}

{{/*
Release-scoped selector: every pod this release owns, the migration Job's pods
included. Used by the NetworkPolicy, because a migration needs the same database
egress as the service whose schema it is changing.

Kept minimal on purpose: anything that moves with a release (the version, the
chart) belongs in `eventa-library.labels` only, since a Deployment's selector is
immutable once created.
*/}}
{{- define "eventa-library.selectorLabels" -}}
app.kubernetes.io/name: {{ include "eventa-library.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Workload selector: the long-running pods only.

The component label is part of the selector so that the pre-deploy migration Job
(`component: migration`) falls outside it. Without that, the Job's pods would
carry the Deployment's selector labels and so be picked up by this workload's
Service — which would route live requests to a pod running `migrate` and serving
nothing — and counted by its PodDisruptionBudget. The NetworkPolicy deliberately
uses the broader selector above and still covers them.
*/}}
{{- define "eventa-library.podSelectorLabels" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{ include "eventa-library.selectorLabels" . }}
app.kubernetes.io/component: {{ $v.component }}
{{- end -}}

{{- define "eventa-library.labels" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
helm.sh/chart: {{ include "eventa-library.chart" . }}
{{ include "eventa-library.selectorLabels" . }}
{{- with include "eventa-library.versionLabel" . }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{- with $v.component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
app.kubernetes.io/part-of: {{ $v.partOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with $v.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Annotations shared by every object: whatever the chart adds, plus the Argo CD
sync wave that orders the rollout (devops-ci-cd.md §4.3).
*/}}
{{- define "eventa-library.annotations" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- with $v.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- if ne (toString $v.argocd.syncWave) "" }}
argocd.argoproj.io/sync-wave: {{ $v.argocd.syncWave | quote }}
{{- end }}
{{- end -}}

{{/*
Per-object annotations: the common set, with the object's own annotations
layered over it. Renders nothing at all when both are empty, so templates can
wrap it in `with` and not emit a stray `annotations:` key.

Call with (dict "ctx" . "extra" <map>).
*/}}
{{- define "eventa-library.mergedAnnotations" -}}
{{- $common := fromYaml (include "eventa-library.annotations" .ctx) | default dict -}}
{{- $merged := mergeOverwrite $common (deepCopy (.extra | default dict)) -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end -}}

{{/*
The image reference. A digest wins over a tag when both are set, because
devops-ci-cd.md §3 promotes the exact signed digest that CI scanned.
*/}}
{{- define "eventa-library.image" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- $repo := required "image.repository is required: the chart cannot guess which of the four images it deploys (devops-ci-cd.md §0)." $v.image.repository -}}
{{- if $v.image.digest -}}
{{- printf "%s@%s" $repo $v.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (required "image.tag is required and must be an immutable git-SHA tag, never a moving alias (devops-ci-cd.md §3)." $v.image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "eventa-library.serviceAccountName" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.serviceAccount.create -}}
{{- default (include "eventa-library.fullname" .) $v.serviceAccount.name -}}
{{- else -}}
{{- default "default" $v.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "eventa-library.configMapName" -}}
{{- printf "%s-config" (include "eventa-library.fullname" .) -}}
{{- end -}}

{{/* The Secret the External Secrets Operator materialises for this workload. */}}
{{- define "eventa-library.secretName" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- default (printf "%s-secrets" (include "eventa-library.fullname" .)) $v.externalSecret.target.name -}}
{{- end -}}

{{/*
The environment name (dev | staging | uat | prod | preview-*), per the matrix in
devops-infrastructure.md §7. The namespace already encodes it, so that is the
fallback rather than a guess.
*/}}
{{- define "eventa-library.environment" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- default .Release.Namespace $v.environment -}}
{{- end -}}

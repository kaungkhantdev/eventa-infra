{{/*
The Deployment skeleton. One Deployment per service, plus the check-in pool as
its own Deployment (devops-infrastructure.md §3.2).
*/}}
{{- define "eventa-library.deployment" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.deployment.enabled -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "eventa-library.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
    {{- with $v.deployment.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.deployment.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  {{- if $v.singleton.enabled }}
  {{- /*
    Pinned to one replica, and not by the value: the number is written here so
    that no values file, `--set`, or Argo CD parameter override can raise it.

    The relay's outbox reader takes no row lock —
    eventa-relay/src/relay/outbox-reader.repository.ts:25 selects pending rows
    on `isNull(publishedAt)` with no `FOR UPDATE SKIP LOCKED`, and
    eventa-relay/src/main.ts:20 states that scaling it safely needs that lock
    first. A second replica selects the same rows and publishes every message
    twice; consumers dedupe on message id only AFTER the first copy completes,
    so both concurrent copies are handled and one registration sends the buyer
    two confirmation emails.

    devops-infrastructure.md §3.2 tabulates relay at 2 replicas. That entry is a
    defect in the document, not a target: eventa-infra/README.md and the source
    comment above both say one replica, and `_validate.tpl` fails the render if
    anyone sets `replicas` higher. Check the reader for the lock before lifting
    either.
  */}}
  replicas: 1
  {{- else if not $v.hpa.enabled }}
  replicas: {{ $v.replicas }}
  {{- else }}
  {{- /*
    No `replicas` here on purpose. The HPA owns the field, and Argo CD runs with
    self-heal and drift detection (devops-infrastructure.md §1.3): a replica
    count in Git is drift the moment the HPA scales out, and self-heal would
    scale the workload back down in the middle of the on-sale burst it just
    scaled up for.
  */}}
  {{- end }}
  revisionHistoryLimit: {{ $v.revisionHistoryLimit }}
  progressDeadlineSeconds: {{ $v.progressDeadlineSeconds }}
  selector:
    matchLabels:
      {{- include "eventa-library.podSelectorLabels" . | nindent 6 }}
  strategy:
    {{- if $v.singleton.enabled }}
    {{- /*
      A surge is a second replica. devops-ci-cd.md §4.2 and §5.3 give the relay
      maxSurge=0 / maxUnavailable=1 — the old publisher stops before the new one
      starts, so a rollout narrows publishing to zero for a moment rather than
      running two overlapping publishers. Forced here rather than defaulted,
      because inheriting the library's maxSurge=1 would reintroduce the
      double-publish on every single deploy.
    */}}
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
    {{- else }}
    type: {{ $v.updateStrategy.type }}
    {{- if eq $v.updateStrategy.type "RollingUpdate" }}
    rollingUpdate:
      {{- toYaml $v.updateStrategy.rollingUpdate | nindent 6 }}
    {{- end }}
    {{- end }}
  template:
    {{- include "eventa-library.podTemplate" . | nindent 4 }}
{{- end -}}
{{- end -}}

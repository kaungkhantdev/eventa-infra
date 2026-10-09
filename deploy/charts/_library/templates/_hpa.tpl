{{/*
HorizontalPodAutoscaler.

devops-infrastructure.md §3.2 fixes the signal per workload: CPU + RPS for web,
CPU + RPS + p95 latency for api, CPU + RPS + check-in queue depth for checkin,
CPU + RabbitMQ queue depth for worker — and nothing for relay, which ships with
no HPA at all until its reader takes a row lock (see `_validate.tpl`).

CPU and memory get first-class knobs because every scaled workload uses CPU.
The rest pass through `hpa.metrics` verbatim: RPS, p95 latency and queue depth
arrive as Pods/Object/External metrics whose names belong to whichever
Prometheus adapter an environment runs, and no document names one — inventing a
metric name here would produce an HPA that reports <unknown> forever.

`scaleTargetRef` points at a Deployment by default. The api is canary-deployed
with Argo Rollouts (devops-ci-cd.md §4.2), where the HPA must target the Rollout
instead, so the kind and apiVersion are overridable.
*/}}
{{- define "eventa-library.hpa" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if and $v.hpa.enabled (not $v.singleton.enabled) -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "eventa-library.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.hpa.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  scaleTargetRef:
    apiVersion: {{ $v.hpa.scaleTargetRef.apiVersion | default "apps/v1" }}
    kind: {{ $v.hpa.scaleTargetRef.kind | default "Deployment" }}
    name: {{ $v.hpa.scaleTargetRef.name | default (include "eventa-library.fullname" .) }}
  {{- /*
    §6: never 0 for prod services. A preview environment legitimately sets 0 —
    devops-infrastructure.md §8 scales previews to zero when idle — so the floor
    is a per-environment value rather than a constant.
  */}}
  minReplicas: {{ $v.hpa.minReplicas }}
  maxReplicas: {{ $v.hpa.maxReplicas }}
  metrics:
    {{- with $v.hpa.cpu.targetAverageUtilization }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
    {{- with $v.hpa.memory.targetAverageUtilization }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
    {{- with $v.hpa.metrics }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $v.hpa.behavior }}
  {{- /*
    §6 asks for stabilization windows so autoscaling does not flap. Scaling out
    may be fast — an on-sale burst is already happening — while scaling in waits
    out a five-minute window, so a lull between two bursts does not discard the
    capacity the next burst needs.
  */}}
  behavior:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
{{- end -}}

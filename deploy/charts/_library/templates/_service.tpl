{{/*
A ClusterIP Service per workload.

Only web, api and checkin take ingress traffic (devops-infrastructure.md §3.3),
but the worker also serves a port — it answers probes and /metrics without
serving requests — so whether a Service is rendered is a per-chart decision
(`service.enabled`) rather than something this library infers from the
component.

The public path is CDN → WAF → load balancer → Ingress → Service (§2); nothing
here is ever a LoadBalancer or NodePort, because the only ingress into the VPC
is the one load balancer Terraform owns.
*/}}
{{- define "eventa-library.service" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.service.enabled -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "eventa-library.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
    {{- with $v.service.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.service.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $v.service.type }}
  {{- with $v.service.clusterIP }}
  clusterIP: {{ . }}
  {{- end }}
  selector:
    {{- include "eventa-library.podSelectorLabels" . | nindent 4 }}
  ports:
    {{- toYaml $v.service.ports | nindent 4 }}
{{- end -}}
{{- end -}}

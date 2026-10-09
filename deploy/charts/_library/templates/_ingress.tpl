{{/*
Ingress, for the three workloads that take public traffic (web, api, checkin —
devops-infrastructure.md §3.3).

This is not the edge. The public path is CDN → WAF → public load balancer →
ingress controller → this object (§2), so TLS, OWASP rules and rate limits are
already handled in front of it and nothing here should try to repeat them. The
class and the annotations are per-environment because the controller runs in
`platform` (§3.1) and the hostnames differ by environment (§7, and the
`pr-<n>.preview.eventa.dev` previews in devops-ci-cd.md §1.1).
*/}}
{{- define "eventa-library.ingress" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.ingress.enabled -}}
{{- $fullname := include "eventa-library.fullname" . -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $fullname }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.ingress.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  {{- with $v.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with $v.ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range $host := $v.ingress.hosts }}
    - host: {{ $host.host | quote }}
      http:
        paths:
          {{- range $path := $host.paths }}
          - path: {{ $path.path }}
            pathType: {{ $path.pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $fullname }}
                port:
                  {{- /*
                    A named port keeps the number in values.ports only; a number
                    is accepted too for a Service that exposes one.
                  */}}
                  {{- if kindIs "string" ($path.port | default "http") }}
                  name: {{ $path.port | default "http" }}
                  {{- else }}
                  number: {{ $path.port }}
                  {{- end }}
          {{- end }}
    {{- end }}
{{- end -}}
{{- end -}}

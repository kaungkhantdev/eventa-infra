{{/*
Probe blocks, parameterised so an HTTP service and a no-HTTP consumer both use
the same template.

devops-infrastructure.md §3.3 fixes the shape:
  readiness  GET /health/ready  — checks DB/Redis/broker, gates traffic and
                                  rolling updates
  liveness   GET /health/live   — process-alive only, restarts a wedged pod
  startup    on api and worker  — covers a cold NestJS boot before liveness
                                  starts counting
and sends workloads with no HTTP server to exec/TCP checks that assert the
broker connection instead.

The `type` field selects the handler, because a Kubernetes probe carries exactly
one and an inherited default of a second one makes the manifest invalid.
*/}}

{{/*
One probe's body. Call with (dict "cfg" <probe values> "kind" "readiness").
*/}}
{{- define "eventa-library.probe" -}}
{{- $cfg := .cfg -}}
{{- if eq $cfg.type "http" }}
httpGet:
  path: {{ $cfg.http.path }}
  port: {{ $cfg.http.port }}
  scheme: {{ $cfg.http.scheme | default "HTTP" }}
  {{- with $cfg.http.httpHeaders }}
  httpHeaders:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- else if eq $cfg.type "exec" }}
exec:
  command:
    {{- toYaml $cfg.exec.command | nindent 4 }}
{{- else if eq $cfg.type "tcp" }}
tcpSocket:
  port: {{ $cfg.tcp.port }}
{{- end }}
{{- with $cfg.initialDelaySeconds }}
initialDelaySeconds: {{ . }}
{{- end }}
periodSeconds: {{ $cfg.periodSeconds }}
timeoutSeconds: {{ $cfg.timeoutSeconds }}
failureThreshold: {{ $cfg.failureThreshold }}
{{- if eq .kind "readiness" }}
{{- /*
  successThreshold is only settable on readiness: the API server requires 1 for
  liveness and startup, so it is not emitted for them.
*/}}
successThreshold: {{ $cfg.successThreshold | default 1 }}
{{- end }}
{{- end -}}

{{/*
All three probes, as container-level keys. Call with the root context.
*/}}
{{- define "eventa-library.probes" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.probes.startup.enabled }}
startupProbe:
  {{- include "eventa-library.probe" (dict "cfg" $v.probes.startup "kind" "startup") | trim | nindent 2 }}
{{- end }}
{{- if $v.probes.readiness.enabled }}
readinessProbe:
  {{- include "eventa-library.probe" (dict "cfg" $v.probes.readiness "kind" "readiness") | trim | nindent 2 }}
{{- end }}
{{- if $v.probes.liveness.enabled }}
livenessProbe:
  {{- include "eventa-library.probe" (dict "cfg" $v.probes.liveness "kind" "liveness") | trim | nindent 2 }}
{{- end }}
{{- end -}}

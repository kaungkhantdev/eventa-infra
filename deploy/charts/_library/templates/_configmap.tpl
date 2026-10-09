{{/*
Non-secret configuration.

devops-infrastructure.md §5: config is not secret and secret is never in Git.
Everything here comes from `values-<env>.yaml`, is committed, and is readable by
anyone with the repo — log level, feature flags, region, queue names. Anything
that would not survive that is a secret and belongs in the ExternalSecret;
`_validate.tpl` rejects a key here whose name reads like a credential.

Values are stringified because a ConfigMap's `data` is string-to-string: a
numeric `PORT: 3000` left as an integer makes the API server reject the object,
and typed env parsing is the application's job (every service validates its own
env — see e.g. eventa-api/src/config/env.validation.ts).
*/}}
{{- define "eventa-library.configmap.body" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- $data := dict -}}
{{- range $key, $val := ($v.config.env | default dict) -}}
{{- $data = set $data $key (toString $val) -}}
{{- end -}}
{{- toYaml $data -}}
{{- end -}}

{{- define "eventa-library.configmap" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if and $v.config.enabled $v.config.env -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "eventa-library.configMapName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.config.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
data:
  {{- include "eventa-library.configmap.body" . | nindent 2 }}
{{- end -}}
{{- end -}}

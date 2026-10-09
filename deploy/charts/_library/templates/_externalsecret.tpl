{{/*
ExternalSecret — the only way a secret reaches a pod.

devops-infrastructure.md §5: the External Secrets Operator watches these CRs and
materialises a Kubernetes Secret from the managed secrets manager at runtime.
Git holds the reference (path + key), never the value, and no secret ever lands
in an image, a ConfigMap, or a values file. `_validate.tpl` refuses to render a
`config.env` key whose name reads like a credential, so the two paths cannot be
confused by accident.

`refreshInterval` is what makes rotation zero-touch (§5): the secrets manager
rotates DB and broker credentials on a schedule and the operator re-syncs within
the interval. Note that re-syncing the Secret does not by itself restart the
pods that read it as env vars — that needs a reload controller watching the
Secret, which no document names, so it is left to a per-environment
`podAnnotations` entry rather than invented here.

`creationPolicy: Owner` ties the Secret's lifecycle to the CR;
`deletionPolicy: Retain` keeps the materialised Secret if the remote path
disappears, so a secrets-manager outage or a mistyped path does not delete the
credentials out from under running pods.

The CRD's group version is a value, not a constant: it has moved across
operator releases and no document pins the version this platform runs.
*/}}
{{- define "eventa-library.externalsecret" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.externalSecret.enabled -}}
apiVersion: {{ $v.externalSecret.apiVersion }}
kind: ExternalSecret
metadata:
  name: {{ include "eventa-library.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" dict) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  refreshInterval: {{ $v.externalSecret.refreshInterval }}
  secretStoreRef:
    name: {{ $v.externalSecret.secretStoreRef.name }}
    kind: {{ $v.externalSecret.secretStoreRef.kind }}
  target:
    name: {{ include "eventa-library.secretName" . }}
    creationPolicy: {{ $v.externalSecret.target.creationPolicy }}
    deletionPolicy: {{ $v.externalSecret.target.deletionPolicy }}
    {{- with $v.externalSecret.target.template }}
    template:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- with $v.externalSecret.dataFrom }}
  dataFrom:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $v.externalSecret.data }}
  data:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
{{- end -}}

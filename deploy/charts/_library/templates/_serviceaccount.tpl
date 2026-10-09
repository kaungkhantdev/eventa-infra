{{/*
One ServiceAccount per workload, because the secrets-manager grant is attached
to it.

devops-infrastructure.md §5 gives each namespace least-privilege access to its
own secret path (`/eventa/dev/*` … `/eventa/prod/*`) through workload identity,
so a dev pod cannot read prod secrets. The binding is an annotation whose key
differs per cloud, and §1.1 names the mechanism neutrally ("IRSA/
workload-identity") because no provider has been chosen — so the annotation
arrives from `values-<env>.yaml` and this chart does not guess at its shape.

The token is not mounted by default: none of the five workloads talks to the
Kubernetes API, and an unmounted token is one fewer credential in the pod.
*/}}
{{- define "eventa-library.serviceaccount" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "eventa-library.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.serviceAccount.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ $v.serviceAccount.automountServiceAccountToken }}
{{- end -}}
{{- end -}}

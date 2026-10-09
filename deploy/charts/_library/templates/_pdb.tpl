{{/*
PodDisruptionBudget.

devops-infrastructure.md §3.3: `minAvailable: 50%` per service, so a node drain
or a cluster upgrade never takes a service below quorum, and so HPA scale-in
respects it too (§6).

The relay overrides this to the literal `minAvailable: 1` the same section asks
for ("relay uses maxUnavailable: 0 behavior via minAvailable: 1 to keep at least
one publisher live"). Worth knowing before the first node drain: with one
replica, `minAvailable: 1` leaves zero allowed disruptions, so `kubectl drain`
on the relay's node blocks until an operator deletes the pod by hand. That is
the trade the document chose — a momentary gap in publishing is recoverable
because the outbox row survives (devops-ci-cd.md §5.3), while two concurrent
publishers are not — and it is the reason the relay is the one workload a node
drain cannot fully automate.
*/}}
{{- define "eventa-library.pdb" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.pdb.enabled -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "eventa-library.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.pdb.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "eventa-library.podSelectorLabels" . | nindent 6 }}
  {{- /*
    minAvailable and maxUnavailable are IntOrString: a percentage has to stay a
    quoted string ("50%") and a count has to stay a bare integer (1). Quoting
    both would turn `1` into the string "1", which the API server rejects, so
    the two cases are rendered separately.
  */}}
  {{- if and (hasKey $v.pdb "minAvailable") (not (kindIs "invalid" $v.pdb.minAvailable)) (ne (toString $v.pdb.minAvailable) "") }}
  minAvailable: {{ if kindIs "string" $v.pdb.minAvailable }}{{ $v.pdb.minAvailable | quote }}{{ else }}{{ $v.pdb.minAvailable }}{{ end }}
  {{- else }}
  maxUnavailable: {{ if kindIs "string" $v.pdb.maxUnavailable }}{{ $v.pdb.maxUnavailable | quote }}{{ else }}{{ $v.pdb.maxUnavailable }}{{ end }}
  {{- end }}
{{- end -}}
{{- end -}}

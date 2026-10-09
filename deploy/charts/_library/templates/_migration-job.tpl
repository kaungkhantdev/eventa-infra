{{/*
The gated pre-deploy migration Job.

devops-ci-cd.md §5.1 and devops-infrastructure.md §3.3: schema changes run as a
Kubernetes Job before new pods roll, never inside app startup. Argo CD runs it
as a `PreSync` hook in sync wave 1 and halts the sync if it exits non-zero, so
no pod ever starts against an un-migrated schema.

`backoffLimit: 0` is deliberate. Migrations are forward-only (§5.1), so a failed
one needs a human to look at a schema that may be half-changed; a retry would
re-run the same statements against that state. The pre-deploy gate is the place
a bad migration is supposed to stop (§8.2), and it only stops things if it does
not retry.

Only the api chart enables this: eventa-api owns every migration, while worker
and relay keep typed mirrors of the tables they touch. Ordering matters in one
direction — a migration that adds an enum value must ship before, or with, the
services whose mirrors use it, because a lagging mirror fails on write and so
fails in production rather than in CI (eventa-infra/README.md, devops-ci-cd.md
§5.3).

It reuses the workload's own image, config, secrets and service account, because
a migration runs the same code as the service and must read the same database
credentials; probes and the HPA are the only things it does not share.
*/}}
{{- define "eventa-library.migrationJob" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.migrationJob.enabled -}}
apiVersion: batch/v1
kind: Job
metadata:
  {{- /*
    A fixed name, which works because the hook-delete policy is
    BeforeHookCreation: Argo CD removes the previous Job immediately before
    creating this one, so each sync gets a fresh Job without accumulating one
    object per revision.
  */}}
  name: {{ include "eventa-library.fullname" . }}-migrate
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
    {{- with $v.migrationJob.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.migrationJob.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  backoffLimit: {{ $v.migrationJob.backoffLimit }}
  {{- /*
    §5.1 wraps migrations in lock and statement timeouts to avoid long table
    locks; this is the outer bound on the whole Job, so a migration that blocks
    on a lock fails the gate instead of holding the deploy open indefinitely.
  */}}
  activeDeadlineSeconds: {{ $v.migrationJob.activeDeadlineSeconds }}
  {{- with $v.migrationJob.ttlSecondsAfterFinished }}
  ttlSecondsAfterFinished: {{ . }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "eventa-library.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: migration
      {{- with $v.migrationJob.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- with $v.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      restartPolicy: Never
      serviceAccountName: {{ include "eventa-library.serviceAccountName" . }}
      automountServiceAccountToken: {{ $v.serviceAccount.automountServiceAccountToken }}
      {{- with $v.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with include "eventa-library.volumes" . }}
      volumes:
        {{- . | trim | nindent 8 }}
      {{- end }}
      containers:
        - name: migrate
          image: {{ include "eventa-library.image" . }}
          imagePullPolicy: {{ $v.image.pullPolicy }}
          {{- with $v.migrationJob.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.migrationJob.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.migrationJob.extraEnv }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with include "eventa-library.envFrom" . }}
          envFrom:
            {{- . | trim | nindent 12 }}
          {{- end }}
          {{- /*
            Falls back to the workload's own requests and limits. A migration
            container with no requests is BestEffort, so it is the first thing
            the kubelet evicts under node pressure — and being evicted halfway
            through a schema change is the one failure the pre-deploy gate
            exists to avoid.
          */}}
          resources:
            {{- toYaml ($v.migrationJob.resources | default $v.resources) | nindent 12 }}
          {{- with $v.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with include "eventa-library.volumeMounts" . }}
          volumeMounts:
            {{- . | trim | nindent 12 }}
          {{- end }}
{{- end -}}
{{- end -}}

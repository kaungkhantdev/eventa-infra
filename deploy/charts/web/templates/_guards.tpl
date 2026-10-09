{{/*
Refusals that belong to the web chart alone.

A guard renders nothing. It exists so a values file that would produce a
working-looking but wrong manifest fails at `helm template` — in CI, where
somebody is reading the output — rather than in a cluster, where the first
symptom is behavioural.
*/}}

{{- define "eventa-web.guards" -}}
{{- if dig "migrationJob" "enabled" false (fromYaml (toYaml .Values)) -}}
{{- fail "[web] migrationJob.enabled is true. Refusing to render.\n\nThe Job carries no command of its own, so it would run the web image's default entrypoint — an extra SSR server outside the Deployment, taking no traffic and governed by no PDB.\n\neventa-api owns every migration (eventa-infra/README.md, third warning) and the api chart owns the single Job: devops-ci-cd.md §5.1 specifies one Argo CD `PreSync` hook in sync wave 1. Leave migrationJob.enabled false." -}}
{{- end -}}
{{- end -}}

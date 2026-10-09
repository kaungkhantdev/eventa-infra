{{/*
The pod template, factored out of the Deployment on purpose.

The api is canary-deployed with Argo Rollouts (devops-ci-cd.md §4.2), so its
chart renders a Rollout rather than a Deployment. A Rollout's `spec.template` is
a pod template like any other, so it embeds `eventa-library.podTemplate` and
inherits the same probes, security context, anti-affinity and env wiring as the
other four workloads — which is the whole point of the library (§1.2).
*/}}

{{/*
Scheduling. devops-infrastructure.md §3.3: "Anti-affinity spreads replicas
across AZs."

Soft (preferred) rather than required: a required zone rule caps the Deployment
at one replica per AZ, so the fourth replica of an on-sale scale-out (§6) would
sit Pending forever while nodes are available. The zone term carries the heavier
weight, with a lighter hostname term so replicas inside one zone still land on
different nodes.

An explicit `affinity` in values replaces all of this.
*/}}
{{- define "eventa-library.affinity" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.affinity -}}
{{- toYaml $v.affinity -}}
{{- else if $v.antiAffinity.enabled -}}
podAntiAffinity:
  {{- if eq $v.antiAffinity.type "hard" }}
  requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: {{ $v.antiAffinity.zoneTopologyKey }}
      labelSelector:
        matchLabels:
          {{- include "eventa-library.podSelectorLabels" . | nindent 10 }}
  {{- else }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: {{ $v.antiAffinity.zoneTopologyKey }}
        labelSelector:
          matchLabels:
            {{- include "eventa-library.podSelectorLabels" . | nindent 12 }}
    - weight: 50
      podAffinityTerm:
        topologyKey: {{ $v.antiAffinity.nodeTopologyKey }}
        labelSelector:
          matchLabels:
            {{- include "eventa-library.podSelectorLabels" . | nindent 12 }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Environment variables.

The two OTEL_* variables are the OpenTelemetry-standard way to state the service
and environment that devops-observability-sre.md §1 requires on every signal —
one correlation model across five workloads, so the names belong here rather
than being reinvented per chart. The SDK in each service reads them without any
application code.
*/}}
{{- define "eventa-library.env" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.telemetry.enabled }}
- name: OTEL_SERVICE_NAME
  value: {{ default (include "eventa-library.name" .) $v.telemetry.serviceName | quote }}
{{- $attrs := list (printf "service.name=%s" (default (include "eventa-library.name" .) $v.telemetry.serviceName)) (printf "deployment.environment=%s" (include "eventa-library.environment" .)) -}}
{{- with include "eventa-library.versionLabel" . }}
{{- $attrs = append $attrs (printf "service.version=%s" .) -}}
{{- end }}
{{- range $key, $val := $v.telemetry.extraResourceAttributes }}
{{- $attrs = append $attrs (printf "%s=%v" $key $val) -}}
{{- end }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ join "," $attrs | quote }}
{{- end }}
{{- with $v.extraEnv }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/*
`envFrom`: the non-secret ConfigMap and the Secret that the External Secrets
Operator materialises. devops-infrastructure.md §5 keeps the two apart —
ConfigMaps come from values-<env>.yaml and are in Git, secret values never are.
*/}}
{{- define "eventa-library.envFrom" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if and $v.config.enabled $v.config.env }}
- configMapRef:
    name: {{ include "eventa-library.configMapName" . }}
{{- end }}
{{- if and $v.externalSecret.enabled $v.externalSecret.injectAsEnv }}
- secretRef:
    name: {{ include "eventa-library.secretName" . }}
{{- end }}
{{- with $v.extraEnvFrom }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{- define "eventa-library.volumes" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.tmpDir.enabled }}
- name: tmp
  emptyDir:
    {{- with $v.tmpDir.medium }}
    medium: {{ . }}
    {{- end }}
    {{- with $v.tmpDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
{{- end }}
{{- with $v.extraVolumes }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{- define "eventa-library.volumeMounts" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.tmpDir.enabled }}
- name: tmp
  mountPath: {{ $v.tmpDir.mountPath }}
{{- end }}
{{- with $v.extraVolumeMounts }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/*
The pod template: `metadata` + `spec`, ready to be nested under a Deployment's
or a Rollout's `spec.template`.
*/}}
{{- define "eventa-library.podTemplate" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
metadata:
  labels:
    {{- include "eventa-library.podSelectorLabels" . | nindent 4 }}
    app.kubernetes.io/part-of: {{ $v.partOf }}
    {{- with $v.commonLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with $v.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    {{- if and $v.config.enabled $v.config.env }}
    {{- /*
      A ConfigMap edit reaches no running process on its own. Hashing the
      rendered ConfigMap into the pod template means a config change rolls the
      pods, so the cluster cannot end up disagreeing with Git about what the
      config is while Argo CD reports Synced.
    */}}
    checksum/config: {{ include "eventa-library.configmap.body" . | sha256sum }}
    {{- end }}
    {{- if and $v.metrics.enabled $v.metrics.podAnnotations }}
    {{- /*
      devops-observability-sre.md §1 has all five workloads scraped on /metrics.
      Which scraper is not specified, so these vendor-neutral annotations are
      emitted and no ServiceMonitor is — that CRD exists only if the Prometheus
      Operator is installed, and nothing commits to it.
    */}}
    prometheus.io/scrape: "true"
    prometheus.io/path: {{ $v.metrics.path | quote }}
    prometheus.io/port: {{ include "eventa-library.metricsPortNumber" . | quote }}
    {{- end }}
    {{- with $v.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with $v.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "eventa-library.serviceAccountName" . }}
  automountServiceAccountToken: {{ $v.serviceAccount.automountServiceAccountToken }}
  {{- with $v.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- /*
    devops-ci-cd.md §5.3: workers and the relay drain on SIGTERM — stop taking
    new messages, finish in-flight handlers, ack, exit — so this must exceed the
    longest handler or Kubernetes SIGKILLs a handler mid-flight.
  */}}
  terminationGracePeriodSeconds: {{ $v.terminationGracePeriodSeconds }}
  {{- with $v.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with $v.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $v.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with include "eventa-library.affinity" . }}
  affinity:
    {{- . | trim | nindent 4 }}
  {{- end }}
  {{- with $v.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with include "eventa-library.volumes" . }}
  volumes:
    {{- . | trim | nindent 4 }}
  {{- end }}
  containers:
    - name: {{ include "eventa-library.name" . }}
      image: {{ include "eventa-library.image" . }}
      imagePullPolicy: {{ $v.image.pullPolicy }}
      {{- with $v.command }}
      command:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.ports }}
      ports:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with include "eventa-library.env" . }}
      env:
        {{- . | trim | nindent 8 }}
      {{- end }}
      {{- with include "eventa-library.envFrom" . }}
      envFrom:
        {{- . | trim | nindent 8 }}
      {{- end }}
      {{- with include "eventa-library.probes" . }}
      {{- . | trim | nindent 6 }}
      {{- end }}
      resources:
        {{- toYaml $v.resources | nindent 8 }}
      {{- with $v.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.lifecycle }}
      lifecycle:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with include "eventa-library.volumeMounts" . }}
      volumeMounts:
        {{- . | trim | nindent 8 }}
      {{- end }}
{{- end -}}

{{/*
The container port number behind `metrics.port`, which may be a name or a
number. The scrape annotation needs the number.
*/}}
{{- define "eventa-library.metricsPortNumber" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if kindIs "string" $v.metrics.port -}}
{{- $found := "" -}}
{{- range $p := ($v.ports | default list) -}}
{{- if eq $p.name $v.metrics.port -}}{{- $found = $p.containerPort -}}{{- end -}}
{{- end -}}
{{- $found -}}
{{- else -}}
{{- $v.metrics.port -}}
{{- end -}}
{{- end -}}

{{/*
Contract validation. Runs once per `eventa-library.values` call, which every
other template starts with, so a chart that violates the contract fails at
`helm template` time — in CI, on a laptop, in an Argo CD diff — rather than
producing a manifest that a cluster accepts and then misbehaves.

It is called with (dict "v" <merged values> "ctx" <root context>) and must never
call a helper that itself calls `eventa-library.values`, or the two would
recurse.

Nothing here is style. Each check corresponds to a failure that is silent,
expensive, or both.
*/}}
{{- define "eventa-library.validate" -}}
{{- $v := .v -}}
{{- $ctx := .ctx -}}
{{- $chart := $ctx.Chart.Name -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Identity and image                                                 */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if not $v.component -}}
{{- fail (printf "[%s] values.component is required. It becomes app.kubernetes.io/component, and it is the only label that tells the `api` and `checkin` pools apart — they run the same image in the same namespace (devops-infrastructure.md §3.2). Set it to one of: web, api, checkin, worker, relay." $chart) -}}
{{- end -}}
{{- if not $v.image.repository -}}
{{- fail (printf "[%s] values.image.repository is required (devops-ci-cd.md §0 fixes the four images: web, api, worker, relay)." $chart) -}}
{{- end -}}
{{- if and (not $v.image.tag) (not $v.image.digest) -}}
{{- fail (printf "[%s] set image.tag to an immutable git-SHA tag, or image.digest to a signed digest. devops-ci-cd.md §3: deployments always reference the SHA, never a moving alias such as `latest` or `:main`, and promotion between environments moves that pinned reference (devops-infrastructure.md §1.2)." $chart) -}}
{{- end -}}
{{- if or (eq (toString $v.image.tag) "latest") (eq (toString $v.image.tag) "main") -}}
{{- fail (printf "[%s] image.tag is %q, a moving alias. devops-ci-cd.md §3 requires an immutable SHA tag so that what ran in staging is byte-for-byte what runs in prod, and so a rollback is deterministic (§8.1)." $chart $v.image.tag) -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Resources                                                          */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  A pod with no requests is BestEffort: it is the first thing evicted under node
  pressure, and a CPU-target HPA has no denominator so it never scales. Both
  failures appear under exactly the load the autoscaling exists for. The numbers
  per workload are tabulated in devops-infrastructure.md §3.3.
*/ -}}
{{- range $side := list "requests" "limits" -}}
{{- range $kind := list "cpu" "memory" -}}
{{- if not (dig $side $kind "" $v.resources) -}}
{{- fail (printf "[%s] values.resources.%s.%s is required. devops-infrastructure.md §3.3 tabulates CPU and memory requests AND limits for all five workloads; a pod without requests is BestEffort and a CPU-based HPA cannot compute a target for it." $chart $side $kind) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Ports and probes                                                   */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- $portNames := list -}}
{{- range $p := ($v.ports | default list) -}}
{{- /*
  A null entry would otherwise surface as "nil pointer evaluating
  interface {}.name" from whichever template dereferenced it first. It happens
  for a real reason: `--set ports[1].name=…` replaces the whole list and leaves
  index 0 null, because this library merges lists wholesale rather than
  element-wise.
*/ -}}
{{- if kindIs "invalid" $p -}}
{{- fail (printf "[%s] values.ports contains an empty entry. Set the whole list in values rather than one index with --set: `--set ports[1].…` replaces the list and leaves the earlier indexes null." $chart) -}}
{{- end -}}
{{- if not $p.name -}}
{{- fail (printf "[%s] every entry in values.ports needs a name: probes, the Service and the metrics scrape all address ports by name so the number lives in one place." $chart) -}}
{{- end -}}
{{- if has $p.name $portNames -}}
{{- fail (printf "[%s] values.ports has two ports named %q; port names must be unique within a pod." $chart $p.name) -}}
{{- end -}}
{{- $portNames = append $portNames $p.name -}}
{{- end -}}

{{- range $probe := list "readiness" "liveness" "startup" -}}
{{- $cfg := index $v.probes $probe -}}
{{- if $cfg.enabled -}}
{{- if not (has $cfg.type (list "http" "exec" "tcp")) -}}
{{- fail (printf "[%s] probes.%s.type is %q; it must be http, exec or tcp. A Kubernetes probe carries exactly one handler, so the type selects which block is rendered — worker and relay have no HTTP server of their own to probe (devops-infrastructure.md §3.3)." $chart $probe $cfg.type) -}}
{{- end -}}
{{- if eq $cfg.type "http" -}}
{{- if not $cfg.http.path -}}
{{- fail (printf "[%s] probes.%s.http.path is empty. §3.3 fixes the endpoints: readiness GET /health/ready (checks DB/Redis/broker, gates traffic and rolling updates), liveness GET /health/live (process-alive only)." $chart $probe) -}}
{{- end -}}
{{- if not $cfg.http.port -}}
{{- fail (printf "[%s] probes.%s.http.port is empty." $chart $probe) -}}
{{- end -}}
{{- if and (kindIs "string" $cfg.http.port) (not (has $cfg.http.port $portNames)) -}}
{{- fail (printf "[%s] probes.%s.http.port is %q, which is not a port declared in values.ports (%s). A probe against an undeclared port name never succeeds, and a readiness probe that never succeeds means the rollout stalls with no traffic served." $chart $probe $cfg.http.port (join ", " $portNames)) -}}
{{- end -}}
{{- else if eq $cfg.type "exec" -}}
{{- if not $cfg.exec.command -}}
{{- fail (printf "[%s] probes.%s.type is exec but probes.%s.exec.command is empty. §3.3 points workers and the relay at exec/TCP checks plus broker-connection health precisely because they answer no HTTP; the command has to assert that connection, not just that the process exists." $chart $probe $probe) -}}
{{- end -}}
{{- else if eq $cfg.type "tcp" -}}
{{- if not $cfg.tcp.port -}}
{{- fail (printf "[%s] probes.%s.tcp.port is empty." $chart $probe) -}}
{{- end -}}
{{- if and (kindIs "string" $cfg.tcp.port) (not (has $cfg.tcp.port $portNames)) -}}
{{- fail (printf "[%s] probes.%s.tcp.port is %q, which is not a port declared in values.ports (%s)." $chart $probe $cfg.tcp.port (join ", " $portNames)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  A liveness probe that checks a dependency restarts every pod at once when that
  dependency blips, turning a recoverable Redis failover into a cluster-wide
  crash loop. §3.3 is explicit that liveness is process-alive only, so pointing
  it at the readiness endpoint is a mistake worth catching here.
*/ -}}
{{- if and $v.probes.liveness.enabled (eq $v.probes.liveness.type "http") -}}
{{- if contains "ready" ($v.probes.liveness.http.path | toString) -}}
{{- fail (printf "[%s] probes.liveness.http.path is %q, which looks like the readiness endpoint. devops-infrastructure.md §3.3: liveness is process-alive only; readiness checks DB/Redis/broker. A liveness probe that checks dependencies restarts every replica simultaneously the moment a dependency blips." $chart $v.probes.liveness.http.path) -}}
{{- end -}}
{{- end -}}

{{- if $v.metrics.enabled -}}
{{- if and (kindIs "string" $v.metrics.port) (not (has $v.metrics.port $portNames)) -}}
{{- fail (printf "[%s] metrics.port is %q, which is not a port declared in values.ports (%s). All five workloads expose /metrics for Prometheus (devops-observability-sre.md §1)." $chart $v.metrics.port (join ", " $portNames)) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Config and secrets (devops-infrastructure.md §5)                   */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  "Config is not secret, secret is never in Git." A credential pasted into
  `config.env` lands in a ConfigMap and in the Git history, and nothing about
  the rendered manifest looks wrong — so the name is checked here. The escape
  hatch is config.allowSecretLookingKeys, for the values that really are public.
*/ -}}
{{- $secretish := list "PASSWORD" "PASSWD" "SECRET" "TOKEN" "PRIVATE_KEY" "API_KEY" "APIKEY" "CREDENTIAL" "_DSN" "DATABASE_URL" "REDIS_URL" "AMQP_URL" "RABBITMQ_URL" "SMTP_PASS" "SIGNING" -}}
{{- $allowed := $v.config.allowSecretLookingKeys | default list -}}
{{- range $key, $_ := ($v.config.env | default dict) -}}
{{- $upper := upper (toString $key) -}}
{{- if not (has (toString $key) $allowed) -}}
{{- range $needle := $secretish -}}
{{- if contains $needle $upper -}}
{{- fail (printf "[%s] config.env.%s reads like a credential, and config.env renders into a ConfigMap that is committed to Git. devops-infrastructure.md §5: secrets reach the cluster only through the External Secrets Operator, and Git holds the reference (path + key), never the value. Move it to externalSecret.data / externalSecret.dataFrom, or list the key in config.allowSecretLookingKeys if the value really is public." $chart $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- if $v.externalSecret.enabled -}}
{{- if and (not $v.externalSecret.data) (not $v.externalSecret.dataFrom) -}}
{{- fail (printf "[%s] externalSecret.enabled is true but both data and dataFrom are empty. That renders an ExternalSecret which materialises an EMPTY Secret: the pod starts, mounts nothing, and fails on its first database call instead of failing to deploy. Declare the per-environment paths (/eventa/<env>/* per devops-infrastructure.md §5)." $chart) -}}
{{- end -}}
{{- if not $v.externalSecret.secretStoreRef.name -}}
{{- fail (printf "[%s] externalSecret.secretStoreRef.name is required." $chart) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* Disruption and autoscaling                                         */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if $v.pdb.enabled -}}
{{- $hasMin := and (hasKey $v.pdb "minAvailable") (ne (toString $v.pdb.minAvailable) "") (not (kindIs "invalid" $v.pdb.minAvailable)) -}}
{{- $hasMax := and (hasKey $v.pdb "maxUnavailable") (ne (toString $v.pdb.maxUnavailable) "") (not (kindIs "invalid" $v.pdb.maxUnavailable)) -}}
{{- if and $hasMin $hasMax -}}
{{- fail (printf "[%s] pdb.minAvailable and pdb.maxUnavailable are mutually exclusive; the API server rejects a PodDisruptionBudget carrying both. §3.3 asks for minAvailable: 50%% per service (relay: 1), so clear maxUnavailable." $chart) -}}
{{- end -}}
{{- if and (not $hasMin) (not $hasMax) -}}
{{- fail (printf "[%s] pdb.enabled is true but neither minAvailable nor maxUnavailable is set. §3.3 requires a budget per service so node drains and cluster upgrades never take a service below quorum." $chart) -}}
{{- end -}}
{{- end -}}

{{- if $v.hpa.enabled -}}
{{- if lt (int $v.hpa.maxReplicas) 1 -}}
{{- fail (printf "[%s] hpa.maxReplicas must be at least 1." $chart) -}}
{{- end -}}
{{- if gt (int $v.hpa.minReplicas) (int $v.hpa.maxReplicas) -}}
{{- fail (printf "[%s] hpa.minReplicas (%d) exceeds hpa.maxReplicas (%d)." $chart (int $v.hpa.minReplicas) (int $v.hpa.maxReplicas)) -}}
{{- end -}}
{{- if and (not $v.hpa.cpu.targetAverageUtilization) (not $v.hpa.memory.targetAverageUtilization) (not $v.hpa.metrics) -}}
{{- fail (printf "[%s] hpa.enabled is true but no metric is configured. An HPA with an empty metrics list reports <unknown> and scales nothing, so the workload looks autoscaled and is not. The signal per workload is fixed in devops-infrastructure.md §3.2." $chart) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* NetworkPolicy (devops-infrastructure.md §3.3)                      */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  The managed data services sit in private data subnets outside the cluster
  (§2), so their allows are CIDR blocks. A NetworkPolicy egress rule with an
  empty `to` list does not deny anything — it allows egress to every
  destination. An unset CIDR therefore has to be an error, not a default.
*/ -}}
{{- if $v.networkPolicy.enabled -}}
{{- $fallbacks := dict "postgres" (dig "eventa" "network" "postgresCidrs" list $v.global) "redis" (dig "eventa" "network" "redisCidrs" list $v.global) "rabbitmq" (dig "eventa" "network" "rabbitmqCidrs" list $v.global) -}}
{{- range $store := list "postgres" "redis" "rabbitmq" -}}
{{- $cfg := index $v.networkPolicy.egress $store -}}
{{- if $cfg.enabled -}}
{{- $cidrs := $cfg.cidrs | default (index $fallbacks $store) -}}
{{- if not $cidrs -}}
{{- fail (printf "[%s] networkPolicy.egress.%s.enabled is true but no CIDR is set. %s is a managed service in a private data subnet (devops-infrastructure.md §2), not a pod, so the allow is an ipBlock; the range comes from the Terraform network module output for this environment. Rendering the rule with an empty `to` would allow egress to EVERY destination, which is the opposite of the default-deny posture in §3.3. Set networkPolicy.egress.%s.cidrs, or global.eventa.network.%sCidrs for all five charts at once." $chart $store $store $store $store) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /*
  Same null-entry trap as values.ports, and worse here: a null peer renders as a
  rule with no selector, which allows every pod rather than none.
*/ -}}
{{- range $key := list "fromPods" "toPods" -}}
{{- $list := list -}}
{{- if eq $key "fromPods" -}}{{- $list = $v.networkPolicy.ingress.fromPods | default list -}}{{- else -}}{{- $list = $v.networkPolicy.egress.toPods | default list -}}{{- end -}}
{{- range $peer := $list -}}
{{- if kindIs "invalid" $peer -}}
{{- fail (printf "[%s] networkPolicy.%s contains an empty entry, which would render a rule with no peer selector — allowing every pod instead of the declared one. Set the whole list in values." $chart $key) -}}
{{- end -}}
{{- if and (not $peer.podSelector) (not $peer.namespaceSelector) (not $peer.namespace) -}}
{{- fail (printf "[%s] an entry in networkPolicy.%s declares no namespace, namespaceSelector or podSelector. §3.3 allows no pod-to-pod traffic that is not declared, and a peer with no selector matches everything." $chart $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $v.networkPolicy.ingress.fromIngressController.enabled (not $v.networkPolicy.ingress.fromIngressController.podSelector) (not $v.networkPolicy.ingress.fromIngressController.namespaceSelector) (not $v.networkPolicy.ingress.fromIngressController.namespace) -}}
{{- fail (printf "[%s] networkPolicy.ingress.fromIngressController is enabled with no namespace, namespaceSelector or podSelector, which would admit traffic from every pod in the cluster. The ingress controller runs in the `platform` namespace (devops-infrastructure.md §3.1)." $chart) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* The singleton guard — relay                                        */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- if $v.singleton.enabled -}}
{{- /*
  The chart's own values, round-tripped through YAML because `.Values` is a
  `chartutil.Values` and `dig` needs a plain map.
*/ -}}
{{- $raw := fromYaml (toYaml $ctx.Values) -}}
{{- $name := default $chart $v.nameOverride -}}
{{- /*
  Checked against the chart's OWN values, not the merged set: this library
  defaults `replicas` to 2 for the four scalable workloads, and inheriting a
  default is not someone asking for a second publisher. What has to fail is an
  explicit `replicas:` in the relay's values, a `values-<env>.yaml`, an Argo CD
  parameter override, or a `--set` on the command line — each of which lands
  here. The Deployment writes `replicas: 1` as a literal regardless.
*/ -}}
{{- $explicitReplicas := dig "replicas" nil $raw -}}
{{- if and (not (kindIs "invalid" $explicitReplicas)) (gt (int $explicitReplicas) 1) -}}
{{- fail (include "eventa-library.singleton.replicasMessage" (dict "name" $name "replicas" (int $explicitReplicas) "reason" $v.singleton.reason "evidence" $v.singleton.evidence)) -}}
{{- end -}}
{{- if $v.hpa.enabled -}}
{{- fail (include "eventa-library.singleton.hpaMessage" (dict "name" $name "minReplicas" (int $v.hpa.minReplicas))) -}}
{{- end -}}
{{- /*
  A surge is a second replica. On a one-replica singleton the default rolling
  strategy (maxSurge 1 / maxUnavailable 0) starts the new pod BEFORE the old one
  stops, so two publishers run concurrently for the length of the rollout — the
  exact condition the single replica exists to prevent. devops-ci-cd.md §4.2 and
  §5.3 call for maxSurge=0 / maxUnavailable=1 for the relay, a brief
  single-replica cutover. The Deployment template forces that; this check exists
  so that a chart which explicitly asks for a surge is told, rather than quietly
  corrected.
*/ -}}
{{- $explicitSurge := dig "updateStrategy" "rollingUpdate" "maxSurge" nil $raw -}}
{{- if and (not (kindIs "invalid" $explicitSurge)) (ne (toString $explicitSurge) "0") (ne (toString $explicitSurge) "0%") -}}
{{- fail (include "eventa-library.singleton.surgeMessage" (dict "name" $name "maxSurge" (toString $explicitSurge))) -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/*
The guard's three messages, kept out of the logic above so they can be long
enough to be useful. Each one says what broke, why the rule exists, where the
evidence is, and what has to happen before the rule can go away.
*/}}
{{- define "eventa-library.singleton.replicasMessage" -}}
SINGLETON GUARD — refusing to render the `{{ .name }}` chart.

replicas is set to {{ .replicas }}, and this workload is declared a singleton.
{{ if .reason }}
Why: {{ .reason }}
{{ end }}
The relay's outbox reader takes no row lock. Verified in the source, not assumed:

  eventa-relay/src/relay/outbox-reader.repository.ts:25
      selects pending rows on `isNull(outboxEvents.publishedAt)` with no
      `FOR UPDATE SKIP LOCKED`.

  eventa-relay/src/main.ts:20
      "Scaling this safely needs `FOR UPDATE SKIP LOCKED` in the reader first."

With two replicas both readers select the same rows and publish every message
twice. Consumers dedupe on message id, but only AFTER the first copy has
finished — two copies delivered concurrently are both handled. For a
registration that means two confirmation emails to the same buyer.

Note that devops-infrastructure.md §3.2 tabulates `relay` at a minimum of 2
replicas. That entry is a defect in the document: the code it describes cannot
support it. This guard exists so the defect cannot reach a cluster.

To lift the guard: land `FOR UPDATE SKIP LOCKED` in the reader
{{- if .evidence }} ({{ .evidence }}){{ end }}, then drop `singleton` from this
chart's values in the same change — and only then raise `replicas`.
{{- end -}}

{{- define "eventa-library.singleton.hpaMessage" -}}
SINGLETON GUARD — refusing to render the `{{ .name }}` chart.

hpa.enabled is true (minReplicas {{ .minReplicas }}) on a workload declared a
singleton, so this chart would ship an autoscaler whose whole job is to create
the second replica that must not exist.

devops-infrastructure.md §6 lists "relay scales with outbox lag", and that is
the right design once the reader takes a row lock. Until
`FOR UPDATE SKIP LOCKED` lands in
eventa-relay/src/relay/outbox-reader.repository.ts:25, a second replica
double-publishes every outbox row (see eventa-relay/src/main.ts:20), so the
relay ships with no HPA at all.

Outbox lag is still the signal to watch — it just pages a human instead of
adding a replica. devops-observability-sre.md §2 sets the thresholds: warn above
30s, page above 120s.
{{- end -}}

{{- define "eventa-library.singleton.surgeMessage" -}}
SINGLETON GUARD — refusing to render the `{{ .name }}` chart.

updateStrategy.rollingUpdate.maxSurge is set to {{ .maxSurge }} on a workload
declared a singleton. A surge IS a second replica: the new pod starts before the
old one stops, so two publishers run concurrently for the length of every
rollout — the precise condition the single replica exists to prevent, arriving
on every deploy rather than permanently.

devops-ci-cd.md §4.2 and §5.3 specify maxSurge=0 / maxUnavailable=1 for the
relay: a brief single-replica cutover with no overlap. Set maxSurge to 0, or
leave updateStrategy unset and let this library apply it for you.
{{- end -}}

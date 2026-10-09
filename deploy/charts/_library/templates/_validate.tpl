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
{{- /*
  The library's own peers must select PODS, not just a namespace.

  A peer with no selector at all admits every pod in the cluster, which is what
  the fromIngressController check used to catch. But the form it was meant to
  prevent also arrives one step narrower, and that form used to pass: a peer
  with a `namespace` and an empty `podSelector` renders as a bare
  namespaceSelector, and §3.1 puts Argo CD, External Secrets, the ingress
  controller AND the observability agents in the single `platform` namespace. So
  the narrower form still let the Argo CD repo-server, or any vendor agent
  installed alongside it, open a direct connection to this workload — past the
  CDN → WAF → load balancer path that §2's table calls the "only ingress path
  into the VPC", and against §3.3's "No pod-to-pod that isn't declared", since a
  namespace is not a declaration.

  Both forms are refused here. `_defaults.tpl` ships a placeholder podSelector
  for each of these peers so the shape is right out of the box; it is accepted
  because it fails closed (no pod carries that label) and shows up verbatim in
  the rendered object, whereas failing the render would make the library
  unusable before an ingress controller and an observability stack have been
  chosen — and §3.1 names neither.

  Scope: the two peers the library itself supplies a default for. `fromPods` is
  checked above instead, because there the chart author writes the peer out,
  which is what §3.3 means by declaring it. `egress.dns` already ships
  `k8s-app: kube-dns` for the same reason this check exists, but it is left
  unchecked rather than guessed at — it is an egress peer to a namespace this
  platform does not own, and tightening it is not this finding.

  What this check actually guards, stated plainly rather than overclaimed: a
  chart's values cannot reach the namespace-only form today. `podSelector: {}`
  in a values file does not clear the default, because `eventa-library.values`
  merges with `mergeOverwrite`, which leaves a non-empty destination alone when
  the source value is empty; and `podSelector: null` is rejected first by the
  chart's own values.schema.json, where the field is typed `object`. So the form
  this refuses is the one that arrives by editing the DEFAULT in
  `_defaults.tpl` back to `{}` — which is exactly how it got shipped the first
  time. The check turns that edit into a failed render instead of five quietly
  widened policies.
*/ -}}
{{- range $name := list "fromIngressController" "fromMetricsScraper" -}}
{{- $peer := index $v.networkPolicy.ingress $name -}}
{{- if $peer.enabled -}}
{{- if and (not $peer.podSelector) (not $peer.namespaceSelector) (not $peer.namespace) -}}
{{- fail (printf "[%s] networkPolicy.ingress.%s is enabled with no namespace, namespaceSelector or podSelector, which would admit traffic from every pod in the cluster. devops-infrastructure.md §3.1 places the ingress controller, Argo CD, External Secrets and the observability agents in the `platform` namespace." $chart $name) -}}
{{- end -}}
{{- if and (not $peer.podSelector) (not $peer.namespaceSelector) -}}
{{- fail (printf "[%s] networkPolicy.ingress.%s selects the namespace %q and no pods, so it admits every pod in it. §3.1 puts Argo CD, External Secrets, the ingress controller and the observability agents in one namespace, so that peer admits all four — the opposite of §3.3's \"No pod-to-pod that isn't declared\", and a way around the CDN → WAF → load balancer path §2 calls the only ingress path into the VPC. Set networkPolicy.ingress.%s.podSelector to the labels of the pods actually allowed to connect, or networkPolicy.ingress.%s.namespaceSelector if the peer genuinely is every pod in some namespace." $chart $name $peer.namespace $name $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /*
  Node CIDRs for kubelet probe traffic, the same trap as the data stores: an
  ingress rule with an empty `from` admits every source rather than none, so an
  unset CIDR has to be an error.
*/ -}}
{{- if $v.networkPolicy.ingress.fromNodes.enabled -}}
{{- if not ($v.networkPolicy.ingress.fromNodes.cidrs | default (dig "eventa" "network" "nodeCidrs" list $v.global)) -}}
{{- fail (printf "[%s] networkPolicy.ingress.fromNodes.enabled is true but no CIDR is set. The kubelet probes from the node's own address, so the peer can only be an ipBlock — the private app subnets of devops-infrastructure.md §2, per environment, from the Terraform network module. Rendering the rule with an empty `from` would admit EVERY source, which is the opposite of §3.3's default-deny. Set networkPolicy.ingress.fromNodes.cidrs, or global.eventa.network.nodeCidrs for all five charts at once." $chart) -}}
{{- end -}}
{{- end -}}
{{- /*
  Egress ports must be numbers.

  Inbound rules may name a container port, because the library resolves the name
  against values.ports before rendering (see `_networkpolicy.tpl`). Outbound
  rules cannot: the destination is an ipBlock, or pods belonging to a different
  workload whose port names this chart does not know. The API would leave such a
  name to the CNI to resolve per destination pod, and no CNI has been chosen —
  the same gap recorded for FQDN egress. A name here would therefore render a
  rule that matches nothing, so it is refused rather than emitted.
*/ -}}
{{- $egressPortLists := dict
    "egress.dns.ports" $v.networkPolicy.egress.dns.ports
    "egress.postgres.ports" $v.networkPolicy.egress.postgres.ports
    "egress.redis.ports" $v.networkPolicy.egress.redis.ports
    "egress.rabbitmq.ports" $v.networkPolicy.egress.rabbitmq.ports
    "egress.external.ports" $v.networkPolicy.egress.external.ports -}}
{{- range $i, $peer := ($v.networkPolicy.egress.toPods | default list) -}}
{{- $egressPortLists = set $egressPortLists (printf "egress.toPods[%d].ports" $i) $peer.ports -}}
{{- end -}}
{{- range $path, $ports := $egressPortLists -}}
{{- range $p := ($ports | default list) -}}
{{- if and (not (kindIs "invalid" $p)) (kindIs "string" $p.port) (not (regexMatch "^[0-9]+$" $p.port)) -}}
{{- fail (printf "[%s] networkPolicy.%s uses the port name %q. An egress rule's destination is an ipBlock or another workload's pods, so this chart cannot resolve the name and the CNI would have to resolve it per destination pod — and no CNI has been chosen (devops-infrastructure.md names no network plugin), which is the same reason FQDN egress is not used. Write the number. Inbound rules may use a name because the library resolves it against values.ports." $chart $path $p.port) -}}
{{- end -}}
{{- end -}}
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

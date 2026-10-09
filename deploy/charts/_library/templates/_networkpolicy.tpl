{{/*
NetworkPolicies.

devops-infrastructure.md §3.3: default-deny per namespace, then explicit allows
— ingress → web/api/checkin; api/checkin/worker/relay → Postgres/Redis/RabbitMQ;
worker/relay → RabbitMQ; egress to Stripe/PromptPay/comms via NAT only. "No
pod-to-pod that isn't declared."

Two things decide the shape of this template:

  * The data stores are managed services in private data subnets (§2), not pods
    in this cluster, so their allows are ipBlock CIDRs that come from the
    Terraform network module per environment — never a podSelector.

  * A NetworkPolicy rule with an empty peer list allows everything rather than
    nothing. An unset CIDR is therefore a render error (`_validate.tpl`), not a
    quiet default, because the mistake would otherwise read as a tightening and
    behave as an opening.

Plain NetworkPolicy cannot express "egress to Stripe" by hostname; FQDN rules
need a CNI-specific CRD and no CNI has been chosen. `egress.external` is
therefore the honest approximation: these ports, anywhere, minus every private
range — which still prevents the workload from reaching the rest of the VPC.

The rules are assembled as data and serialised once with `toYaml`. Hand-indented
YAML fragments nest wrongly the moment a peer gains a second key, and a
NetworkPolicy that parses but selects the wrong thing fails open.

Three further properties of the rendered object, each of which used to be an
unexplained inconsistency:

  * EVERY PORT IS A NUMBER, inbound and outbound alike. A container-port name
    in any `ports` list is resolved through `values.ports` by
    `eventa-library.netpol.resolvePorts` before it reaches the manifest.

    This template used to emit the NAME for its ingress allows while
    `web/values.yaml` wrote the number 3000 for its egress allow and explained
    that "a named port in a NetworkPolicy is resolved per destination pod by the
    CNI, and no CNI has been chosen" — two opposite answers to one question.
    The number wins both times, for two reasons:

      1. The CNI argument applies inbound as well. `NetworkPolicyPort.port`
         accepts a name, but nothing in the API guarantees an implementation
         resolves it; that is the same bet the FQDN note above refuses to make.
      2. Inbound resolution is not even against a single pod set here. This
         policy's `spec.podSelector` is `eventa-library.selectorLabels` — name
         plus instance — which by design also covers the pre-deploy migration
         Job's pods (see the docblock on that helper in `_helpers.tpl`), and the
         `migrate` container declares no ports at all. So `port: http` resolves
         to 3000 for the service's pods and to nothing for the Job's.

    Resolving here is strictly better than either: `values.ports` is in hand, so
    a name that does not exist becomes a render error rather than a rule that
    quietly matches no traffic.

  * IDENTICAL RULES ARE COLLAPSED. `fromIngressController` and
    `fromMetricsScraper` could resolve to the same peer and the same port and
    render twice, byte for byte — which made turning one of the two flags off
    change nothing visible. Kubernetes unions policy rules, so dropping an exact
    duplicate cannot change the effective policy; it only makes the manifest
    mean what the flags say.

  * KUBELET PROBE TRAFFIC IS NOT COVERED unless `ingress.fromNodes` is turned
    on. Both policy types are always declared and ingress is allowed only from
    `platform`, so a probe — sent from the node's own address, and a node is
    neither a pod nor in a namespace — matches no rule here. Whether it is
    actually dropped is a CNI property and not an API guarantee: some
    implementations do not apply pod policy to node-sourced traffic at all,
    which is why default-deny namespaces often do not break probes. No CNI has
    been chosen (nothing in devops-infrastructure.md names a network plugin), so
    `fromNodes` exists, takes the app-subnet CIDRs of §2, and is off by default.
*/}}

{{/*
A one-element peer list. Call with (dict "namespace" … "namespaceSelector" …
"podSelector" …); `namespace` is shorthand for selecting that namespace by name.
*/}}
{{- define "eventa-library.netpol.peer" -}}
{{- $peer := dict -}}
{{- if .namespaceSelector -}}
{{- $peer = set $peer "namespaceSelector" .namespaceSelector -}}
{{- else if .namespace -}}
{{- /*
  `kubernetes.io/metadata.name` is set automatically on every namespace by the
  API server, so selecting `platform` or `kube-system` by name needs no extra
  labels on namespaces this chart does not own.
*/ -}}
{{- $peer = set $peer "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" .namespace)) -}}
{{- end -}}
{{- if .podSelector -}}
{{- $peer = set $peer "podSelector" (dict "matchLabels" .podSelector) -}}
{{- end -}}
{{- toYaml (list $peer) -}}
{{- end -}}

{{/* Normalise [{port, protocol}] entries, defaulting the protocol to TCP. */}}
{{- define "eventa-library.netpol.ports" -}}
{{- $out := list -}}
{{- range . -}}
{{- $out = append $out (dict "port" .port "protocol" (default "TCP" .protocol)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
As above, but any port written as a container-port NAME is first resolved to its
number through `values.ports`. See the third bullet of this file's docblock for
why the manifest carries numbers in both directions.

Call with (dict "ports" [{port, protocol}] "declared" <values.ports>
"chart" <chart name> "field" <values path, for the error message>).
*/}}
{{- define "eventa-library.netpol.resolvePorts" -}}
{{- $chart := .chart -}}
{{- $field := .field -}}
{{- $byName := dict -}}
{{- $names := list -}}
{{- range $p := (.declared | default list) -}}
{{- if and (not (kindIs "invalid" $p)) $p.name -}}
{{- $byName = set $byName (toString $p.name) $p.containerPort -}}
{{- $names = append $names (toString $p.name) -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $p := (.ports | default list) -}}
{{- $port := $p.port -}}
{{- if kindIs "string" $port -}}
{{- if hasKey $byName $port -}}
{{- $port = index $byName $port -}}
{{- if kindIs "invalid" $port -}}
{{- fail (printf "[%s] %s names port %q, which is declared in values.ports without a containerPort. The NetworkPolicy needs the number, so there is nothing to render." $chart $field $p.port) -}}
{{- end -}}
{{- else if regexMatch "^[0-9]+$" $port -}}
{{- /*
  A number that arrived quoted — `--set` and some overlays stringify. Accept it
  rather than reporting it as an unknown port name, which is what it would look
  like otherwise.
*/ -}}
{{- $port = atoi $port -}}
{{- else -}}
{{- fail (printf "[%s] %s names port %q, which is not a port declared in values.ports (%s). This library resolves container-port names to numbers when it renders a NetworkPolicy, so an unknown name is an error here rather than a rule that silently matches no traffic." $chart $field $p.port (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- $out = append $out (dict "port" $port "protocol" (default "TCP" $p.protocol)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Namespace-wide default-deny.

It is namespace-scoped, so exactly one release per namespace should own it (see
README). The object is named per release so that two charts enabling it is
additive and harmless — NetworkPolicies union — rather than a Helm ownership
conflict between two Argo CD Applications.
*/}}
{{- define "eventa-library.networkpolicy.defaultDeny" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if and $v.networkPolicy.enabled $v.networkPolicy.defaultDeny.enabled -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "eventa-library.fullname" . }}-default-deny
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.networkPolicy.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  {{- /*
    An empty podSelector selects every pod in the namespace; declaring both
    policy types with no rules denies both directions. Every allow in this
    namespace is then additive on top of it.
  */}}
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
{{- end -}}
{{- end -}}

{{/* The workload's own allows. */}}
{{- define "eventa-library.networkpolicy" -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- if $v.networkPolicy.enabled -}}
{{- $chart := .Chart.Name -}}
{{- $ing := $v.networkPolicy.ingress -}}
{{- $eg := $v.networkPolicy.egress -}}
{{- $net := dig "eventa" "network" dict ($v.global | default dict) -}}
{{- $ingressRules := list -}}
{{- $egressRules := list -}}

{{- /*
  Ingress. §3.3 allows it to web, api and checkin only; the ingress controller
  runs in `platform` (§3.1) and the public path in front of it is CDN → WAF →
  load balancer (§2).
*/ -}}
{{- if $ing.fromIngressController.enabled -}}
{{- $ports := $ing.fromIngressController.ports -}}
{{- if not $ports -}}
{{- /* Default to exactly the ports the container declares, by number. */ -}}
{{- $ports = list -}}
{{- range $p := ($v.ports | default list) -}}
{{- $ports = append $ports (dict "port" $p.containerPort "protocol" (default "TCP" $p.protocol)) -}}
{{- end -}}
{{- end -}}
{{- /*
  The same trap as an empty peer list, one field over: `ports: []` on a rule
  does not restrict the rule to no port, it matches EVERY port. A workload with
  no `values.ports` — the relay declares none — would therefore get a
  wide-open allow from this rule rather than a narrow one, so it is an error.
*/ -}}
{{- if not $ports -}}
{{- fail (printf "[%s] networkPolicy.ingress.fromIngressController is enabled but there is no port to allow: networkPolicy.ingress.fromIngressController.ports is empty and values.ports declares nothing. A NetworkPolicy rule with an empty `ports` list matches every port, so this would admit the ingress controller to the whole pod instead of one port. devops-infrastructure.md §3.3 gives an Ingress to web, api and checkin only — if this workload has no port to serve on, the flag belongs off." $chart) -}}
{{- end -}}
{{- $ingressRules = append $ingressRules (dict
    "from" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $ing.fromIngressController.namespace "namespaceSelector" $ing.fromIngressController.namespaceSelector "podSelector" $ing.fromIngressController.podSelector)))
    "ports" (fromYamlArray (include "eventa-library.netpol.resolvePorts" (dict "ports" $ports "declared" $v.ports "chart" $chart "field" "networkPolicy.ingress.fromIngressController.ports")))) -}}
{{- end -}}

{{- /*
  Prometheus scrapes /metrics on all five workloads
  (devops-observability-sre.md §1) and the observability agents live in
  `platform` (§3.1). Without this allow, applying the default-deny takes every
  scrape target down at once.
*/ -}}
{{- if and $ing.fromMetricsScraper.enabled $v.metrics.enabled -}}
{{- $ingressRules = append $ingressRules (dict
    "from" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $ing.fromMetricsScraper.namespace "namespaceSelector" $ing.fromMetricsScraper.namespaceSelector "podSelector" $ing.fromMetricsScraper.podSelector)))
    "ports" (fromYamlArray (include "eventa-library.netpol.resolvePorts" (dict "ports" (list (dict "port" $v.metrics.port "protocol" "TCP")) "declared" $v.ports "chart" $chart "field" "metrics.port")))) -}}
{{- end -}}

{{- /*
  Kubelet probe traffic, off unless asked for. A probe's source is the node's
  own address, so the peer can only be an ipBlock: a node is neither a pod nor
  in a namespace, and the NetworkPolicy API has no peer that names it. Whether
  the default-deny blocks probes at all depends on the CNI and none has been
  chosen — see the fourth bullet of this file's docblock, and the long comment
  on `fromNodes` in `_defaults.tpl`.

  The CIDRs are the private app subnets of §2, per environment, from the same
  Terraform network module that supplies the data-store ranges. `_validate.tpl`
  refuses `enabled: true` with none, because an ingress rule with an empty
  `from` admits every source rather than none.
*/ -}}
{{- if $ing.fromNodes.enabled -}}
{{- $ports := $ing.fromNodes.ports -}}
{{- if not $ports -}}
{{- $ports = list -}}
{{- range $p := ($v.ports | default list) -}}
{{- $ports = append $ports (dict "port" $p.containerPort "protocol" (default "TCP" $p.protocol)) -}}
{{- end -}}
{{- end -}}
{{- /* `ports: []` matches every port, so an empty list here is an error too. */ -}}
{{- if not $ports -}}
{{- fail (printf "[%s] networkPolicy.ingress.fromNodes is enabled but there is no port to allow: networkPolicy.ingress.fromNodes.ports is empty and values.ports declares nothing. A NetworkPolicy rule with an empty `ports` list matches every port, so this would open the whole pod to the node range rather than the probe's port. Name the probe's port explicitly in networkPolicy.ingress.fromNodes.ports — and note that a workload with no HTTP port is probed by exec, which is not network traffic and needs no allow at all (devops-infrastructure.md §3.3 sends worker and relay to exec/TCP checks)." $chart) -}}
{{- end -}}
{{- $from := list -}}
{{- range $cidr := ($ing.fromNodes.cidrs | default (dig "nodeCidrs" list $net)) -}}
{{- $from = append $from (dict "ipBlock" (dict "cidr" $cidr)) -}}
{{- end -}}
{{- $ingressRules = append $ingressRules (dict
    "from" $from
    "ports" (fromYamlArray (include "eventa-library.netpol.resolvePorts" (dict "ports" $ports "declared" $v.ports "chart" $chart "field" "networkPolicy.ingress.fromNodes.ports")))) -}}
{{- end -}}

{{- /*
  Declared pod-to-pod ingress. These ports are on THIS workload's pods — the
  ones the policy selects — so a container-port name is resolvable here and is
  resolved, like every other inbound port.
*/ -}}
{{- range $peer := ($ing.fromPods | default list) -}}
{{- $rule := dict "from" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $peer.namespace "namespaceSelector" $peer.namespaceSelector "podSelector" $peer.podSelector))) -}}
{{- if $peer.ports -}}
{{- $rule = set $rule "ports" (fromYamlArray (include "eventa-library.netpol.resolvePorts" (dict "ports" $peer.ports "declared" $v.ports "chart" $chart "field" "networkPolicy.ingress.fromPods[].ports"))) -}}
{{- end -}}
{{- $ingressRules = append $ingressRules $rule -}}
{{- end -}}
{{- range $rule := ($ing.extra | default list) -}}
{{- $ingressRules = append $ingressRules $rule -}}
{{- end -}}

{{- /*
  Egress. DNS first: a default-deny namespace blocks name resolution too, and a
  missing DNS allow presents as a broken database rather than a broken policy.
*/ -}}
{{- if $eg.dns.enabled -}}
{{- $egressRules = append $egressRules (dict
    "to" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $eg.dns.namespace "namespaceSelector" $eg.dns.namespaceSelector "podSelector" $eg.dns.podSelector)))
    "ports" (fromYamlArray (include "eventa-library.netpol.ports" $eg.dns.ports))) -}}
{{- end -}}

{{- range $store := list "postgres" "redis" "rabbitmq" -}}
{{- $cfg := index $eg $store -}}
{{- if $cfg.enabled -}}
{{- $cidrs := $cfg.cidrs | default (dig (printf "%sCidrs" $store) list $net) -}}
{{- $to := list -}}
{{- range $cidr := $cidrs -}}
{{- $to = append $to (dict "ipBlock" (dict "cidr" $cidr)) -}}
{{- end -}}
{{- $egressRules = append $egressRules (dict "to" $to "ports" (fromYamlArray (include "eventa-library.netpol.ports" $cfg.ports))) -}}
{{- end -}}
{{- end -}}

{{- /*
  Stripe, PromptPay and the comms providers, reached through the NAT gateway
  (§2). `except` carves out the private ranges so this stays "out to the
  internet" and does not become a licence to talk to the rest of the VPC.
*/ -}}
{{- if $eg.external.enabled -}}
{{- $block := dict "cidr" "0.0.0.0/0" -}}
{{- if $eg.external.exceptCidrs -}}
{{- $block = set $block "except" $eg.external.exceptCidrs -}}
{{- end -}}
{{- $egressRules = append $egressRules (dict
    "to" (list (dict "ipBlock" $block))
    "ports" (fromYamlArray (include "eventa-library.netpol.ports" $eg.external.ports))) -}}
{{- end -}}

{{- /*
  Declared pod-to-pod egress. Unlike the inbound lists above, these ports are
  NOT name-resolved, and that asymmetry is the point rather than an oversight:
  the destination pods belong to a different workload, so this chart's
  values.ports is the wrong table to resolve against, and the API would leave
  the name to the CNI to resolve per destination pod. `_validate.tpl` refuses a
  name in any egress port list for that reason — the number has to be written
  out, as `web/values.yaml` does for the api's 3000.
*/ -}}
{{- range $peer := ($eg.toPods | default list) -}}
{{- $rule := dict "to" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $peer.namespace "namespaceSelector" $peer.namespaceSelector "podSelector" $peer.podSelector))) -}}
{{- if $peer.ports -}}
{{- $rule = set $rule "ports" (fromYamlArray (include "eventa-library.netpol.ports" $peer.ports)) -}}
{{- end -}}
{{- $egressRules = append $egressRules $rule -}}
{{- end -}}
{{- range $rule := ($eg.extra | default list) -}}
{{- $egressRules = append $egressRules $rule -}}
{{- end -}}

{{- /*
  Collapse exact duplicates.

  `fromIngressController` and `fromMetricsScraper` can resolve to the same peer
  and the same port — they did for api, web and checkin, where the metrics port
  IS the container port and both peers pointed at `platform` — and rendered two
  byte-identical ingress rules. Turning either flag off then changed nothing
  visible in the manifest, which is the opposite of what a flag is for.
  `extra` and `fromPods`/`toPods` can collide the same way.

  Dropping an exact duplicate cannot change behaviour: §3.3's model is
  default-deny plus additive allows, and Kubernetes unions a policy's rules, so
  a rule that is byte-identical to one already in the list contributes nothing.
  The comparison is on `toYaml` of the rule, and the ORIGINAL rule object is
  kept rather than a re-parsed copy, so no port loses its type on the way
  through.
*/ -}}
{{- $seen := dict -}}
{{- $deduped := list -}}
{{- range $rule := $ingressRules -}}
{{- $key := toYaml $rule -}}
{{- if not (hasKey $seen $key) -}}
{{- $seen = set $seen $key true -}}
{{- $deduped = append $deduped $rule -}}
{{- end -}}
{{- end -}}
{{- $ingressRules = $deduped -}}
{{- $seen = dict -}}
{{- $deduped = list -}}
{{- range $rule := $egressRules -}}
{{- $key := toYaml $rule -}}
{{- if not (hasKey $seen $key) -}}
{{- $seen = set $seen $key true -}}
{{- $deduped = append $deduped $rule -}}
{{- end -}}
{{- end -}}
{{- $egressRules = $deduped -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "eventa-library.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "eventa-library.labels" . | nindent 4 }}
  {{- with include "eventa-library.mergedAnnotations" (dict "ctx" . "extra" $v.networkPolicy.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  podSelector:
    matchLabels:
      {{- include "eventa-library.selectorLabels" . | nindent 6 }}
  {{- /*
    Both policy types are always declared, so an empty rule list means "deny
    this direction" rather than "this policy has no opinion". worker and relay
    accept no ingress beyond the metrics scrape, and that has to be a denial.
  */}}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    {{- toYaml $ingressRules | nindent 4 }}
  egress:
    {{- toYaml $egressRules | nindent 4 }}
{{- end -}}
{{- end -}}

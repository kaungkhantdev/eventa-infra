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
{{- /* Default to exactly the ports the container declares, by name. */ -}}
{{- $ports = list -}}
{{- range $p := ($v.ports | default list) -}}
{{- $ports = append $ports (dict "port" $p.name "protocol" (default "TCP" $p.protocol)) -}}
{{- end -}}
{{- end -}}
{{- $ingressRules = append $ingressRules (dict
    "from" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $ing.fromIngressController.namespace "namespaceSelector" $ing.fromIngressController.namespaceSelector "podSelector" $ing.fromIngressController.podSelector)))
    "ports" (fromYamlArray (include "eventa-library.netpol.ports" $ports))) -}}
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
    "ports" (list (dict "port" $v.metrics.port "protocol" "TCP"))) -}}
{{- end -}}

{{- range $peer := ($ing.fromPods | default list) -}}
{{- $rule := dict "from" (fromYamlArray (include "eventa-library.netpol.peer" (dict "namespace" $peer.namespace "namespaceSelector" $peer.namespaceSelector "podSelector" $peer.podSelector))) -}}
{{- if $peer.ports -}}
{{- $rule = set $rule "ports" (fromYamlArray (include "eventa-library.netpol.ports" $peer.ports)) -}}
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

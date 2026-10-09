{{/*
The values contract, with its defaults.

This is the one place a shared default lives. `eventa-library.values` merges the
parent chart's values over this document, so a service chart only has to state
what differs from it. Every number traceable to a document carries the section
it came from; a default with no citation is a safe-by-default choice this chart
makes, and the comment says why.

Keys that YAML 1.1 reads as booleans (`y`, `n`, `on`, `off`) are avoided here —
they would silently become `true`/`false` map keys.
*/}}
{{- define "eventa-library.defaults" -}}
# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
# The workload's role, used for the `app.kubernetes.io/component` label. It is
# distinct from the chart name because `checkin` and `api` run the SAME image in
# two Deployments (devops-infrastructure.md §3.2), and only the component label
# tells the two pools apart on a dashboard or in a NetworkPolicy.
component: ""
nameOverride: ""
fullnameOverride: ""
partOf: eventa

# The environment this release targets (dev | staging | uat | prod | preview),
# per the matrix in devops-infrastructure.md §7. Defaults to the release
# namespace, which already encodes it (`eventa-prod`, `preview-pr-42`).
environment: ""

image:
  repository: ""
  # devops-ci-cd.md §3: deployments reference an immutable SHA tag, never
  # `latest` — Argo CD promotes an environment by moving that pinned tag
  # (devops-infrastructure.md §1.2). Set `digest` to pin harder still; it wins
  # over `tag` when both are present, which is what §3's "promotion is by
  # digest, not rebuild" asks for.
  tag: ""
  digest: ""
  pullPolicy: IfNotPresent
imagePullSecrets: []

commonLabels: {}
commonAnnotations: {}

# ---------------------------------------------------------------------------
# Workload
# ---------------------------------------------------------------------------
deployment:
  enabled: true
  annotations: {}
  labels: {}
podAnnotations: {}
podLabels: {}

# Per-workload prod minimums are in devops-infrastructure.md §3.2; this default
# is deliberately the lowest value that is still a pair, so a chart that forgets
# to set it is merely under-provisioned rather than a single point of failure.
# Ignored entirely when `hpa.enabled` — see `_deployment.tpl` for why.
replicas: 2

revisionHistoryLimit: 5
progressDeadlineSeconds: 600

# devops-ci-cd.md §5.3 requires this to exceed the longest message handler for
# worker and relay, which drain on SIGTERM: stop consuming, finish in-flight
# handlers, ack, exit. 60s is a starting point those two charts must raise to
# whatever their slowest handler actually takes.
terminationGracePeriodSeconds: 60

# devops-infrastructure.md §3.3: rolling updates by default, surge one pod and
# never go below the desired count, so a rollout cannot reduce capacity. The api
# overrides this entirely because it is canary-deployed (devops-ci-cd.md §4.2);
# a singleton overrides it in the other direction (see `singleton` below).
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0

# The singleton guard. Enabling it pins the workload to exactly one replica,
# refuses an HPA, and forces a stop-then-start rollout so two copies never run
# at once. Only `relay` sets this — see `_validate.tpl` for the full reason and
# the evidence.
singleton:
  enabled: false
  # Free text shown in the error message when the guard trips, so the next
  # person reads why rather than deleting the guard.
  reason: ""
  # Where to check whether the guard can be lifted yet (file:line).
  evidence: ""

# Argo CD sync wave. devops-ci-cd.md §4.3 fixes the order: (1) the migration
# pre-deploy Job, (2) api/worker/relay, (3) web. Empty means no annotation, so
# each service chart states its own wave rather than inheriting a guess.
argocd:
  syncWave: ""

command: []
args: []
lifecycle: {}

# Starting points per workload are tabulated in devops-infrastructure.md §3.3.
# There is no default: a pod with no requests is BestEffort, is evicted first
# under node pressure, and gives a CPU-target HPA nothing to divide by — so
# `_validate.tpl` refuses to render without them.
resources:
  requests:
    cpu: ""
    memory: ""
  limits:
    cpu: ""
    memory: ""

# Hardened by default. devops-ci-cd.md §3 builds non-root, distroless/slim
# images, so these are assertions about images we already ship rather than new
# constraints. A workload that genuinely needs to write outside /tmp overrides
# `securityContext.readOnlyRootFilesystem` and says why in its own values.
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL

# A writable /tmp, because a read-only root filesystem otherwise breaks Node at
# runtime (the SSR build cache, multipart upload buffering, npm's own temp use)
# and the failure shows up as a 500 under load rather than at startup.
tmpDir:
  enabled: true
  mountPath: /tmp
  medium: ""
  sizeLimit: 64Mi

extraVolumes: []
extraVolumeMounts: []

serviceAccount:
  create: true
  name: ""
  # Where the workload-identity / IRSA binding goes. devops-infrastructure.md §5
  # grants least-privilege secret access per namespace this way, and the
  # annotation key is cloud-specific, so it is supplied per environment rather
  # than hard-coded here — no cloud provider has been chosen.
  annotations: {}
  # None of the five workloads calls the Kubernetes API, so none of them needs a
  # mounted token. Turn it on deliberately if that ever changes.
  automountServiceAccountToken: false

# devops-infrastructure.md §3.3: "anti-affinity spreads replicas across AZs".
# Soft (preferred) rather than required, because a required zone rule caps the
# Deployment at one replica per AZ and would make the fourth replica of an
# on-sale scale-out unschedulable (§6) — the scheduler should prefer spreading
# and still place the pod when it cannot.
antiAffinity:
  enabled: true
  type: soft
  zoneTopologyKey: topology.kubernetes.io/zone
  nodeTopologyKey: kubernetes.io/hostname
# Set this to take over scheduling completely; it replaces everything the
# `antiAffinity` block would have generated.
affinity: {}
topologySpreadConstraints: []
nodeSelector: {}
tolerations: []
# The burstable check-in pool can be backed by its own node pool
# (devops-infrastructure.md §6), which is expressed with nodeSelector +
# tolerations + a priority class per environment.
priorityClassName: ""

# ---------------------------------------------------------------------------
# Ports, Service, metrics
# ---------------------------------------------------------------------------
# Named ports, because every probe and Service target below refers to a port by
# name — a consumer chart changes the number in one place.
ports:
  - name: http
    containerPort: 3000
    protocol: TCP

service:
  enabled: true
  type: ClusterIP
  annotations: {}
  labels: {}
  clusterIP: ""
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP

# devops-observability-sre.md §1: all five workloads expose /metrics for
# Prometheus. The scrape mechanism is not specified, so this chart emits the
# vendor-neutral `prometheus.io/*` pod annotations and does NOT render a
# ServiceMonitor — that CRD only exists if the Prometheus Operator is installed,
# which no document commits to.
metrics:
  enabled: true
  port: http
  path: /metrics
  podAnnotations: true

# ---------------------------------------------------------------------------
# Probes (devops-infrastructure.md §3.3, devops-ci-cd.md §4.3)
# ---------------------------------------------------------------------------
# Each probe picks exactly one handler through `type` (http | exec | tcp) and
# the matching block. The handler blocks coexist in the defaults on purpose:
# `type` selects one, so a consumer switching to `exec` does not have to blank
# out an inherited `http` default to avoid rendering two handlers — which
# Kubernetes rejects.
probes:
  # Readiness gates traffic AND rolling updates, and checks the dependencies
  # (DB/Redis/broker) rather than just the process.
  readiness:
    enabled: true
    type: http
    http:
      path: /health/ready
      port: http
      scheme: HTTP
      httpHeaders: []
    exec:
      command: []
    tcp:
      port: http
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 3
    successThreshold: 1
  # Liveness is process-alive only and restarts a wedged pod. It must never
  # check a dependency: a Postgres blip would then restart every pod at once and
  # turn a recoverable outage into a crash loop.
  liveness:
    enabled: true
    type: http
    http:
      path: /health/live
      port: http
      scheme: HTTP
      httpHeaders: []
    exec:
      command: []
    tcp:
      port: http
    initialDelaySeconds: 10
    periodSeconds: 20
    timeoutSeconds: 3
    failureThreshold: 3
  # Off by default, on for api and worker, which need it to cover a cold NestJS
  # boot before liveness starts counting. 5s × 30 = a 150s boot budget; liveness
  # is suspended entirely until this passes.
  startup:
    enabled: false
    type: http
    http:
      path: /health/live
      port: http
      scheme: HTTP
      httpHeaders: []
    exec:
      command: []
    tcp:
      port: http
    initialDelaySeconds: 0
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 30

# ---------------------------------------------------------------------------
# Configuration and secrets (devops-infrastructure.md §5)
# ---------------------------------------------------------------------------
# Non-secret config only. It renders to a ConfigMap whose checksum annotates the
# pod template, so changing a value rolls the pods — otherwise a ConfigMap edit
# reaches no running process and the environment silently disagrees with Git.
config:
  enabled: true
  env: {}
  annotations: {}
  # `_validate.tpl` rejects a config key whose name reads like a credential.
  # List a key here to tell it the value really is public (a publishable Stripe
  # key, a public API base URL).
  allowSecretLookingKeys: []

# Raw env entries for things a ConfigMap cannot express — downward API, a
# resource field, a key from another Secret.
extraEnv: []
extraEnvFrom: []

# devops-observability-sre.md §1 requires every workload to emit correlated
# traces, logs and metrics tagged with the service and the environment. These
# two variables are the OpenTelemetry-standard way to say that once, instead of
# each service inventing its own pair of names.
telemetry:
  enabled: true
  serviceName: ""
  extraResourceAttributes: {}

# devops-infrastructure.md §5: secret values are never committed; Git holds only
# the reference (path + key) and the External Secrets Operator materialises the
# Secret from the managed secrets manager at runtime.
externalSecret:
  enabled: false
  # Not pinned by any document, and the CRD group version has moved over ESO
  # releases, so it is a value rather than a constant.
  apiVersion: external-secrets.io/v1
  # §5 rotates DB/broker credentials on a schedule and relies on this re-sync to
  # pick them up.
  refreshInterval: 1h
  secretStoreRef:
    name: eventa-secret-store
    kind: ClusterSecretStore
  target:
    name: ""
    creationPolicy: Owner
    deletionPolicy: Retain
    template: {}
  # Per-environment paths, `/eventa/<env>/*` per §5. `dataFrom` pulls a whole
  # path, `data` maps individual keys.
  dataFrom: []
  data: []
  # Mount the materialised Secret as environment variables. Turn it off for a
  # workload that reads a secret from a file instead.
  injectAsEnv: true

# ---------------------------------------------------------------------------
# Autoscaling (devops-infrastructure.md §3.2, §6)
# ---------------------------------------------------------------------------
# Scaling signals per workload are fixed by §3.2: CPU + RPS (web), CPU + RPS +
# p95 latency (api), CPU + RPS + check-in queue depth (checkin), CPU + RabbitMQ
# queue depth (worker), and none at all for relay. CPU has a first-class knob
# because all four scaled workloads use it; the rest arrive through `metrics`,
# which is passed through to autoscaling/v2 verbatim, because their metric names
# belong to whatever Prometheus adapter an environment runs and no document
# names one.
hpa:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  cpu:
    targetAverageUtilization: 70
  memory:
    targetAverageUtilization: null
  metrics: []
  # The api is canary-deployed with Argo Rollouts (devops-ci-cd.md §4.2), where
  # the HPA must target the Rollout rather than a Deployment. Empty means
  # apps/v1 Deployment named after the release.
  scaleTargetRef:
    apiVersion: ""
    kind: ""
    name: ""
  # §6 asks for stabilization windows so autoscaling does not flap. Scaling out
  # is allowed to be fast (an on-sale burst is now); scaling in waits five
  # minutes so a lull between two bursts does not drop the capacity that the
  # next burst needs.
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
        - type: Pods
          value: 4
          periodSeconds: 60
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
      selectPolicy: Max
  annotations: {}

# ---------------------------------------------------------------------------
# Disruption (devops-infrastructure.md §3.3)
# ---------------------------------------------------------------------------
# `minAvailable: 50%` per service, so a node drain or cluster upgrade never
# takes a service below half its replicas. relay overrides this to the literal
# `1` the document asks for.
pdb:
  enabled: true
  minAvailable: 50%
  # Mutually exclusive with minAvailable; set one and leave the other null.
  maxUnavailable: null
  annotations: {}

# ---------------------------------------------------------------------------
# Network (devops-infrastructure.md §3.3)
# ---------------------------------------------------------------------------
# Default-deny per namespace, then explicit allows: ingress → web/api/checkin;
# api/checkin/worker/relay → Postgres/Redis/RabbitMQ; worker/relay → RabbitMQ;
# egress to Stripe/PromptPay/comms via NAT only. Nothing pod-to-pod that is not
# declared here.
#
# The data stores are managed services in private data subnets (§2), not pods in
# this cluster, so their allows are CIDR blocks rather than pod selectors. The
# CIDRs come out of the Terraform network module per environment; this chart
# refuses to render an egress rule with an empty CIDR list, because a
# NetworkPolicy egress rule with no `to` selector allows egress everywhere —
# exactly the opposite of what an unset value should mean.
#
# Every port in a rendered rule is a NUMBER, inbound and outbound alike. A
# container-port NAME written in any `ports` list below is resolved against
# values.ports at render time and emitted as its containerPort. The reasoning is
# in templates/_networkpolicy.tpl; the short version is that named-port
# resolution in a NetworkPolicy is left to the CNI and no CNI has been chosen,
# and that resolving the name here — where values.ports is in hand — turns a
# typo into a render error instead of a rule that matches nothing.
networkPolicy:
  enabled: true
  annotations: {}
  defaultDeny:
    # Namespace-wide, so exactly one release per namespace should own it. It is
    # off here and the README says which chart turns it on; the object is named
    # per release, so two charts enabling it is additive and harmless rather
    # than a Helm ownership conflict.
    enabled: false
  ingress:
    # A peer here must select PODS, not just a namespace. §3.1 puts Argo CD,
    # External Secrets, the ingress controller and the observability agents in
    # one `platform` namespace, so a peer that is only `namespaceSelector:
    # platform` admits all four — the Argo CD repo-server could then open a
    # connection straight to api:3000, bypassing the CDN → WAF → load balancer
    # path that §2's table calls the "only ingress path into the VPC". §3.3's
    # rule is "No pod-to-pod that isn't declared", and a namespace is not a
    # declaration. `_validate.tpl` refuses the namespace-only form.
    #
    # The two podSelectors below are therefore PLACEHOLDERS with the right
    # shape and deliberately wrong values. The key is the standard
    # `app.kubernetes.io/name` label that a component installed from its own
    # chart normally carries; the value cannot be known, because §3.1 says only
    # that these things run in `platform` and names neither the ingress
    # controller nor the observability stack, and neither has been chosen (the
    # same reason `ingress.className` is left unset). Replace them in the
    # chart's values once those choices are made.
    #
    # An unreplaced placeholder fails CLOSED: no pod carries that label, so the
    # allow matches nothing and inbound traffic to the workload stops. That is
    # the safe direction for a policy, and it is visible — the marker string
    # appears verbatim in the rendered object and in an Argo CD diff.
    fromIngressController:
      enabled: false
      namespace: platform
      namespaceSelector: {}
      podSelector:
        app.kubernetes.io/name: REPLACE-ME-ingress-controller
      # Empty means "the container ports this chart declares, by number". See
      # the named-port note in the `egress` section below for why by number.
      ports: []
    fromMetricsScraper:
      enabled: true
      namespace: platform
      namespaceSelector: {}
      podSelector:
        app.kubernetes.io/name: REPLACE-ME-metrics-scraper
    # Kubelet probe traffic. Off by default.
    #
    # Every rendered policy declares `policyTypes: [Ingress, Egress]` and allows
    # ingress only from `platform`, so a readiness or liveness probe matches no
    # rule: the kubelet sends it from the NODE's own address, and a node is not
    # a pod. The NetworkPolicy API has no peer that means "the kubelet" — a node
    # has no namespace and no pod labels — so the only way to name it is its
    # address range, which is why this is a CIDR peer and not a pod peer.
    #
    # Whether probes are actually blocked is a property of the CNI rather than
    # of the API: some implementations do not apply pod policy to traffic
    # sourced from the node at all, which is why a default-deny namespace often
    # does not break probes in practice. No CNI has been chosen for this cluster
    # — nothing in devops-infrastructure.md names a network plugin, and §3 says
    # only "managed Kubernetes" — so this is recorded as a caveat, the same way
    # FQDN egress is below. Do not assume probes work; do not assume they break.
    #
    # Off by default because enabling it widens ingress, and because the range
    # would have to be the private app subnets of §2 — a per-environment value
    # from the Terraform network module, exactly like the data-store CIDRs
    # below. `_validate.tpl` refuses `enabled: true` with no CIDR, because a
    # NetworkPolicy ingress rule with an empty `from` admits every source rather
    # than none. Turn it on if probes are observed failing under the
    # default-deny, not pre-emptively.
    fromNodes:
      enabled: false
      # Falls back to global.eventa.network.nodeCidrs when empty.
      cidrs: []
      # Empty means "the container ports this chart declares, by number", which
      # is where an HTTP probe lands. A probe aimed at a port that is not in
      # values.ports needs an explicit entry here.
      ports: []
    # Declared pod-to-pod ingress: [{namespace, namespaceSelector, podSelector,
    # ports: [{port, protocol}]}]
    fromPods: []
    extra: []
  egress:
    # Every workload resolves names, and a default-deny namespace blocks DNS
    # first. A missing DNS allow looks like a broken database, not a broken
    # policy, so this is on by default.
    dns:
      enabled: true
      namespace: kube-system
      namespaceSelector: {}
      podSelector:
        k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    postgres:
      enabled: false
      cidrs: []
      ports:
        - port: 5432
          protocol: TCP
    redis:
      enabled: false
      cidrs: []
      ports:
        - port: 6379
          protocol: TCP
    rabbitmq:
      enabled: false
      cidrs: []
      ports:
        - port: 5671
          protocol: TCP
    # Stripe, PromptPay and the comms providers, reached through the NAT gateway
    # (§2). Plain NetworkPolicy cannot name a destination by FQDN — that needs a
    # CNI-specific CRD, and no CNI has been chosen — so this is "the internet on
    # these ports, minus every private range", which still keeps the workload
    # out of the rest of the VPC.
    external:
      enabled: false
      ports:
        - port: 443
          protocol: TCP
      exceptCidrs:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
        - 169.254.0.0/16
    toPods: []
    extra: []

# Shared values an umbrella chart can set once instead of repeating them in five
# service charts. Each `networkPolicy.egress.<store>.cidrs` falls back to the
# matching list here when it is empty, and
# `networkPolicy.ingress.fromNodes.cidrs` falls back to `nodeCidrs`.
global:
  eventa:
    network:
      postgresCidrs: []
      redisCidrs: []
      rabbitmqCidrs: []
      # The private app subnets of §2 — the addresses the kubelet probes from.
      # Only read when networkPolicy.ingress.fromNodes is enabled, which it is
      # not by default.
      nodeCidrs: []

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------
# Only web, api and checkin have one (§3.3). The class and annotations are
# per-environment because the ingress controller runs in `platform` (§3.1) and
# the public path is CDN → WAF → load balancer → Ingress (§2).
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts: []
  tls: []

# ---------------------------------------------------------------------------
# Database migrations (devops-ci-cd.md §5.1)
# ---------------------------------------------------------------------------
# A gated pre-deploy Job, never inside app startup. It runs as an Argo CD
# PreSync hook in sync wave 1, and new pods never start against an un-migrated
# schema because a non-zero exit halts the sync.
#
# Only the api chart enables this: eventa-api owns every migration, and worker
# and relay keep typed mirrors of the tables they touch (eventa-infra/README.md).
migrationJob:
  enabled: false
  command: []
  args: []
  # Forward-only (§5.1). A failed migration must stop the deploy for a human to
  # look at, not retry itself against a schema it has already half-changed.
  backoffLimit: 0
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
  podAnnotations: {}
  labels: {}
  resources: {}
  extraEnv: []
{{- end -}}

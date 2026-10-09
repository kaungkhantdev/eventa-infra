{{/*
Worker-specific render-time guards.

`_library/templates/_validate.tpl` already enforces everything that is common to
the five workloads. These four are specific to this chart, and each one
corresponds to a failure that a cluster accepts and then gets wrong QUIETLY —
which is the test eventa-infra/README.md sets for the relay guard and applies
just as well here: make it hard to get wrong, not just documented.

Nothing here is style, and nothing here duplicates the library. A misconfigured
value that produces a crash loop is already loud enough; these are the ones that
produce a green deployment and a missing email.
*/}}
{{- define "eventa-worker.guards" -}}
{{- if dig "migrationJob" "enabled" false (fromYaml (toYaml .Values)) -}}
{{- fail "[worker] migrationJob.enabled is true. Refusing to render.\n\nThe Job carries no command of its own, so it would run the worker image's default entrypoint — a second consumer competing for the same queues, started outside the Deployment the HPA and PDB govern.\n\neventa-api owns every migration (eventa-infra/README.md, third warning) and the api chart owns the single Job: devops-ci-cd.md §5.1 specifies one Argo CD `PreSync` hook in sync wave 1. Leave migrationJob.enabled false." -}}
{{- end -}}
{{- $v := fromYaml (include "eventa-library.values" .) -}}
{{- $env := $v.config.env | default dict -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* 1. PORT must be the port the chart declares                        */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  eventa-worker/src/main.ts:18 listens on PORT. The readiness, liveness and
  startup probes and the Prometheus scrape annotation all address the container
  port named `http`. If the two disagree, every probe connects to a closed port:
  readiness never passes, so the rolling update stalls at the first new pod and
  reports "progress deadline exceeded" with nothing in the container log to
  explain it — the application is healthy and listening somewhere else.
*/ -}}
{{- $httpPort := "" -}}
{{- range $p := ($v.ports | default list) -}}
{{- if eq $p.name "http" -}}{{- $httpPort = $p.containerPort -}}{{- end -}}
{{- end -}}
{{- if not $httpPort -}}
{{- fail "[worker] values.ports has no port named `http`. The probes and the metrics scrape address the worker's HTTP surface by that name; eventa-worker/src/main.ts:18 serves it on PORT (3100 by default — src/config/env.validation.ts:9)." -}}
{{- end -}}
{{- if hasKey $env "PORT" -}}
{{- if ne (toString $env.PORT) (toString $httpPort) -}}
{{- fail (printf "[worker] config.env.PORT is %v but the container port named `http` is %v.\n\neventa-worker/src/main.ts:18 listens on PORT, while this chart's probes and its Prometheus scrape annotation address the `http` port. When the two disagree the pod serves on one port and is probed on another: readiness never succeeds, the rolling update stalls on the first new pod, and the container log shows a worker that started normally.\n\nSet both to the same number, or drop config.env.PORT and let eventa-worker's own default (3100, src/config/env.validation.ts:9) stand — in which case `http` must be 3100." $env.PORT $httpPort) -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* 2. The HPA must watch the queue this worker consumes              */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  devops-infrastructure.md §3.2 scales the worker on "CPU + RabbitMQ queue
  depth". The depth of WHICH queue is a label selector in the HPA, and the queue
  the worker consumes is RABBITMQ_QUEUE in the ConfigMap. Nothing connects the
  two at runtime: if they drift, the HPA happily reports the depth of a queue
  nobody reads, the real backlog grows unattended, and both objects look
  correct in isolation.
*/ -}}
{{- $consumedQueue := $env.RABBITMQ_QUEUE | default "" -}}
{{- range $m := ($v.hpa.metrics | default list) -}}
{{- $watched := dig "external" "metric" "selector" "matchLabels" "queue" "" (fromYaml (toYaml $m)) -}}
{{- if $watched -}}
{{- if not $consumedQueue -}}
{{- fail (printf "[worker] hpa.metrics scales on the depth of queue %q, but config.env.RABBITMQ_QUEUE is not set, so this chart cannot confirm the worker consumes it.\n\neventa-worker/src/config/env.validation.ts:20 defaults the queue to `eventa.worker`. Set config.env.RABBITMQ_QUEUE to the queue this release consumes so the two values are checkable side by side (devops-infrastructure.md §5 lists queue names as config for exactly this reason)." $watched) -}}
{{- end -}}
{{- if ne $watched $consumedQueue -}}
{{- fail (printf "[worker] the HPA scales on the depth of queue %q while this worker consumes %q.\n\ndevops-infrastructure.md §3.2 scales the worker on RabbitMQ queue depth, and devops-observability-sre.md §2 sources that from the RabbitMQ exporter per queue. With the two names different, the autoscaler tracks a queue nobody drains: the worker's own backlog grows with no scale-out, and nothing about either object looks wrong — the HPA reports a healthy metric and the Deployment reports healthy pods.\n\nMake hpa.metrics' `queue` selector and config.env.RABBITMQ_QUEUE the same name." $watched $consumedQueue) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ------------------------------------------------------------------ */ -}}
{{- /* 3 & 4. Production mail                                             */ -}}
{{- /* ------------------------------------------------------------------ */ -}}
{{- /*
  Keyed off NODE_ENV, which is the same switch eventa-worker keys its own
  production refusals off (src/config/env.validation.ts:148 and :182). Telling
  the application it is in production therefore holds this chart to production's
  requirements one render earlier than the application does — in CI, or in an
  Argo CD diff, instead of in a CrashLoopBackOff after the sync.
*/ -}}
{{- if eq (toString ($env.NODE_ENV | default "")) "production" -}}

{{- /*
  The application already refuses this at boot. Catching it here converts a
  post-sync crash loop into a failed render: the deploy never starts, and the
  message says what the failure would have looked like in production.
*/ -}}
{{- if eq (toString ($env.EMAIL_PROVIDER | default "")) "log" -}}
{{- fail "[worker] config.env.EMAIL_PROVIDER is `log` while NODE_ENV is `production`.\n\nThe log provider records a send and drops the message, so sign-up says \"check your inbox\", the outbox drains, every handler reports success, and nobody ever receives a link. eventa-worker refuses to boot on this (src/config/env.validation.ts:148); this guard refuses to render it, so the deploy halts before any pod starts. Set EMAIL_PROVIDER to `smtp` and supply SMTP_HOST, SMTP_USER and SMTP_PASSWORD through the ExternalSecret (devops-infrastructure.md §5)." -}}
{{- end -}}

{{- /*
  This one the application does NOT catch, which is why it is here. Its default
  sender is `Eventa <no-reply@eventa.local>` (src/config/env.validation.ts:99) —
  a syntactically valid address on a domain that does not exist. A production
  worker configured with it sends mail that is syntactically fine and fails SPF
  and DKIM alignment at the recipient, so it is silently junked or rejected
  downstream. Nothing in the cluster reports an error: the handler succeeded,
  the provider accepted the message, and the metric in
  src/metrics/metrics.service.ts counts it as sent.
*/ -}}
{{- $from := toString ($env.EMAIL_FROM | default "") -}}
{{- if not $from -}}
{{- fail "[worker] config.env.EMAIL_FROM is not set and NODE_ENV is `production`.\n\neventa-worker would fall back to `Eventa <no-reply@eventa.local>` (src/config/env.validation.ts:99). That address is syntactically valid on a domain that does not exist, so every confirmation, reminder and announcement fails SPF/DKIM alignment at the recipient and is junked or rejected — with no error anywhere in the cluster, because the provider accepted the message. Set it to a sender on the domain whose SPF and DKIM records the mail provider for THIS environment is configured for." -}}
{{- end -}}
{{- if or (contains "eventa.local" $from) (contains ".invalid" $from) (contains "@localhost" $from) -}}
{{- fail (printf "[worker] config.env.EMAIL_FROM is %q while NODE_ENV is `production`.\n\nThat is a development sender on a domain that does not resolve — it is eventa-worker's own dev default (src/config/env.validation.ts:99). Mail from it fails SPF/DKIM alignment and is junked or rejected at the recipient, silently: the provider accepts the message and the handler records a success. Use a sender on the domain the environment's mail provider holds records for." $from) -}}
{{- end -}}

{{- end -}}
{{- end -}}

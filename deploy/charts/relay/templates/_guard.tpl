{{/*
The relay's own render-time guard.

The library implements the singleton behaviour — `replicas: 1` as a literal in
the Deployment, no HPA, a stop-then-start rollout, and a `fail` on any attempt
to raise the replica count — but all of that hangs off one value,
`singleton.enabled`. The library cannot know that for THIS chart that value is
not a choice: it has no way to tell the workload that must never have a second
instance from the four that must.

So this is the one door the library cannot close, and it is the easy one to walk
through. Someone who reads `devops-infrastructure.md` §3.2, sees `relay: 2`, and
tries to make the chart match it will reach for the guard itself long before
they reach for `replicas` — and turning the guard off is silent, because every
object still renders and the manifest still looks reasonable.

Hence this check. It runs from `templates/workload.yaml` before anything else is
rendered, and it is deliberately not parameterised: there is no value that
switches it off.
*/}}
{{- define "relay.guard" -}}
{{- if not (dig "singleton" "enabled" false (fromYaml (toYaml .Values))) -}}
{{- fail (include "relay.guard.message" .) -}}
{{- end -}}
{{- if dig "migrationJob" "enabled" false (fromYaml (toYaml .Values)) -}}
{{- fail (include "relay.guard.migrationMessage" .) -}}
{{- end -}}
{{- end -}}

{{- define "relay.guard.migrationMessage" -}}
RELAY SINGLETON GUARD — refusing to render the relay chart.

migrationJob.enabled is true. On every other chart that would merely be wrong;
here it breaks the one invariant this chart exists to hold.

The Job carries no command of its own, so it runs the relay image's default
entrypoint — which is the publisher. Enabling it therefore starts a SECOND
publisher beside the pinned one-replica Deployment, and does it without ever
touching the replica count, so the guard above never sees it. Two publishers
read the same unlocked rows and send every event twice; for a registration that
is two confirmation emails to the same buyer.

Migrations are not this chart's to run in any case. eventa-api owns every
migration (eventa-infra/README.md, third warning) and the api chart owns the
single Job — devops-ci-cd.md §5.1 specifies one Argo CD `PreSync` hook in sync
wave 1, whose non-zero exit halts the sync.

Leave migrationJob.enabled false. If you are trying to run a migration, do it
from the api chart.
{{- end -}}

{{- define "relay.guard.message" -}}
RELAY SINGLETON GUARD — refusing to render the relay chart.

singleton.enabled is not true. On this chart that is not a toggle: it is what
makes the Deployment write `replicas: 1` as a literal, suppress the HPA, and
roll with maxSurge=0 so two publishers never overlap. Without it the relay can
be scaled, and scaling the relay duplicates every event in the system.

The reader takes no row lock. Verified in the source, not assumed:

  eventa-relay/src/relay/outbox-reader.repository.ts:25
      `fetchBatch` selects pending rows on `isNull(outboxEvents.publishedAt)`
      and orders by id. There is no `FOR UPDATE SKIP LOCKED`, so two readers
      polling at the same time return the SAME rows.

  eventa-relay/src/main.ts:20
      "Scaling this safely needs `FOR UPDATE SKIP LOCKED` in the reader first."

  eventa-relay/README.md:22-31
      "Run exactly one replica … Until then the deployment must pin
      `replicas: 1`."

Both replicas would publish each row and then mark it published. Consumers
dedupe on message id, but only AFTER the first copy has been handled — two
copies delivered concurrently are both handled. For one registration that is two
confirmation emails to the same buyer, and the buyer is the first to notice.

devops-infrastructure.md §3.2 tabulates `relay` at a minimum of 2 replicas and
§6 says "relay scales with outbox lag". Both describe the right design for a
reader that claims rows; neither matches the reader that exists. eventa-infra's
README records the same thing as warning 1 and asks this chart to "make this
hard to get wrong, not just documented" — which is what this guard is.

HOW TO LIFT IT, in this order and not before:

  1. Land `FOR UPDATE SKIP LOCKED` in
     eventa-relay/src/relay/outbox-reader.repository.ts, so concurrent readers
     claim disjoint rows, and remove the warning in
     eventa-relay/src/main.ts:15-20.
  2. Delete this guard and the `singleton` block from values.yaml in the same
     change, so the chart and the code stop disagreeing at the same commit.
  3. Only then raise `replicas` (and add the HPA on outbox lag that §6 asks
     for), keeping the PodDisruptionBudget at or above one publisher.

Do not reverse that order. Step 3 without step 1 is the double-publish.
{{- end -}}

{{/*
The relay's own render-time guard.

The library implements the singleton behaviour — `replicas: 1` as a literal in
the Deployment, no HPA, a stop-then-start rollout, and a `fail` on any attempt
to raise the replica count — but all of that hangs off one value,
`singleton.enabled`. The library cannot know that for THIS chart that value is
not a choice: it has no way to tell the workload that must never have a second
instance from the four that must.

So this is the one door the library cannot close, and it is the easy one to walk
through. Turning the guard off is silent: every object still renders and the
manifest still looks reasonable, so nothing in the output announces that a
second publisher has become possible. It is also the door that bypasses the
library's own refusals, because every one of them hangs off the value this
switch turns off.

There is a third door, and it is quieter still: `replicaCount`. That is Helm's
conventional key and this library's is `replicas`, so `--set replicaCount=2`
used to render cleanly and change nothing. The outcome was safe — the Deployment
writes the literal `1` — but the operator was told nothing, and somebody who
believes they have two publishers has learned the wrong thing about this chart.
An unknown key cannot be caught in general, but this one is worth naming,
because it is the key a person reaching for a second replica reaches for first.

Hence these checks. They run from `templates/workload.yaml` before anything else
is rendered, and they are deliberately not parameterised: there is no value that
switches them off.
*/}}
{{- define "relay.guard" -}}
{{- if not (dig "singleton" "enabled" false (fromYaml (toYaml .Values))) -}}
{{- fail (include "relay.guard.message" .) -}}
{{- end -}}
{{- if dig "migrationJob" "enabled" false (fromYaml (toYaml .Values)) -}}
{{- fail (include "relay.guard.migrationMessage" .) -}}
{{- end -}}
{{- if hasKey .Values "replicaCount" -}}
{{- fail (include "relay.guard.replicaCountMessage" (dict "value" .Values.replicaCount)) -}}
{{- end -}}
{{- end -}}

{{- define "relay.guard.replicaCountMessage" -}}
RELAY SINGLETON GUARD — refusing to render the relay chart.

replicaCount is set (to {{ .value }}). This library's key is `replicas`, so
`replicaCount` is not read by anything: before this check it was accepted,
ignored, and the chart rendered the one replica it always renders.

That is why it is refused rather than tolerated. The manifest was right and the
operator's belief about it was wrong, which is the worst combination to leave in
place on this particular chart — somebody who thinks they are running two
publishers will reason about outbox lag, about rollouts and about drains as
though a spare exists.

If you meant to inspect or pin the count: it is `replicas`, it is already 1 in
values.yaml, and the Deployment writes `1` as a literal that no value can
change. If you meant to RAISE it, read the refusal under `relay.guard.message`
first — the reader takes no row lock
(eventa-relay/src/relay/outbox-reader.repository.ts:25), so a second publisher
sends every event twice, and devops-infrastructure.md §3.2 pins the relay at
"exactly 1 — a fixed count, not a minimum" for that reason.

Remove `replicaCount`.
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

The specification says the same thing, so there is no version of this chart that
both renders a second publisher and matches the documents. devops-infrastructure.md
§3.2 tabulates `relay` at "exactly 1 — a fixed count, not a minimum" with the
scaling signal "None — no HPA", §3.2 states that "the `relay` is a singleton and
must not be scaled", and §3.2's closing paragraph names this guard itself: the
chart "fails to render if the replica count is raised or its HPA enabled, rather
than trusting this table". Turning the guard off therefore does not bring the
chart into line with the specification — it leaves the chart contradicting both
the specification and the code. eventa-infra's README asks for exactly that: the
constraint should be "hard to get wrong, not just documented".

HOW TO LIFT IT, in this order and not before:

  1. Land `FOR UPDATE SKIP LOCKED` in
     eventa-relay/src/relay/outbox-reader.repository.ts, so concurrent readers
     claim disjoint rows, and remove the warning in
     eventa-relay/src/main.ts:15-20.
  2. Delete this guard and the `singleton` block from values.yaml in the same
     change, so the chart and the code stop disagreeing at the same commit.
  3. Only then raise `replicas` (and add the HPA on outbox lag, which §3.2
     sanctions for that moment and not before: the lag metric "§6 uses for
     alerting can additionally serve as a scaling signal" once the reader
     claims rows), keeping the PodDisruptionBudget at or above one publisher.

Do not reverse that order. Step 3 without step 1 is the double-publish.
{{- end -}}

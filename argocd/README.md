# argocd — the App-of-Apps

Desired state for the cluster. Nothing here was designed in this repo: the
GitOps model is
[devops-infrastructure.md §1.3](../../eventa-docs/07-deployment/devops-infrastructure.md),
the namespaces are §3.1, the environment matrix is §7, and the promotion and
gating rules are
[devops-ci-cd.md §4.1–§4.3](../../eventa-docs/07-deployment/devops-ci-cd.md).
Read those before changing a field here.

## Shape

Three levels, because §1.3 asks for "a root Argo `Application` [that] points at
child apps (one per service per env), so adding a service or environment is a
Git change".

```
root.yaml                     one Application, applied by hand once
  └── apps/                   what the root renders
      ├── projects.yaml         → projects/        (sync wave -1)
      ├── dev.yaml              → environments/dev/
      ├── staging.yaml          → environments/staging/
      ├── uat.yaml              → environments/uat/
      └── prod.yaml             → environments/prod/
          └── environments/<env>/<service>.yaml
                                one Application per service per environment
                                → deploy/charts/<service> + values-<env>.yaml
```

`projects/` holds one `AppProject` per namespace in §3.1 — `eventa-dev`,
`eventa-staging`, `eventa-uat`, `eventa-prod`, `eventa-preview`, `platform`. A
project pins the one repository Applications may read and the one namespace
they may write, so an Application cannot reach another environment even if
someone edits its `destination`.

Every object in this tree is created in the **`platform`** namespace, not in a
namespace called `argocd`, because §3.1 puts "Argo CD, External Secrets,
ingress controller, observability agents" there — and Argo CD only reads
`Application` objects out of its own namespace.

## Bootstrap

```sh
kubectl apply -f argocd/projects/platform.yaml
kubectl apply -f argocd/root.yaml
```

Two commands, and only ever these two. An `Application` is rejected if its
project does not exist, and the project holding the GitOps machinery cannot be
created by an Application that lives inside it — so `platform.yaml` goes first.
Both files come out of Git and both are idempotent; after the first apply the
`eventa-projects` Application adopts `platform.yaml` and reconciles it like any
other manifest.

CI never runs either command. §1.3's pull-based delivery exists so that CI
holds no cluster credentials: it writes image tags into Git and the cluster
comes and fetches them.

## Promotion

`argocd/` contains no image reference at all — no `helm.parameters`, no tag, no
digest. That is the whole promotion model: §1.2 makes the deployed version the
immutable SHA tag in `deploy/charts/<service>/values-<env>.yaml`, so a
promotion is a one-line edit to a values file and never a change in this
directory.

| Env | What moves a build in | What Argo CD does |
| --- | --- | --- |
| dev | CI's bot commits the tag into `values-dev.yaml` on merge to `main` | Auto-syncs |
| staging | The bot bumps `values-staging.yaml` once dev is healthy | Auto-syncs |
| UAT | A PR bumping `values-uat.yaml`, approved by PO/QA (ci-cd §4.1) | Auto-syncs after merge |
| prod | A PR bumping `values-prod.yaml`, approved by the release manager | **Waits.** Reports OutOfSync until a human syncs |

A production promotion therefore has two human steps — approve the PR, then
sync — which is what §1.3 ("prod sync is gated (manual/approved)") and §4.1
("manual approval (release mgr)") describe between them. On sync, the api's
pre-deploy migration Job runs as a `PreSync` hook before any pod rolls
(ci-cd §5.1), then the Rollout steps 10% → 25% → 50% with analysis at each step
(§4.2).

Rollback is the same mechanism in reverse: revert the commit that moved the tag
(§8.1). Because promotion is by digest, the exact previously-running image
returns.

### Why UAT auto-syncs although §7 calls it "gated"

The two documents are precise about where each gate sits. ci-cd §4.1 gates UAT
on a "manual approval (PO/QA)" of the **promotion**; §1.3 and §4.1 reserve a
gated **sync** for production alone. So UAT's gate is the approval on the PR
that moves its tag, and once that is merged there is nothing left to approve.
Production is the only environment whose children have no `syncPolicy.automated`.

## Sync policy

| Application | automated | prune | selfHeal |
| --- | --- | --- | --- |
| `root.yaml`, `apps/*.yaml` | yes | yes | yes |
| `environments/{dev,staging,uat}/*` | yes | yes | yes |
| `environments/prod/*` | **no** | — | — |

The per-environment roots in `apps/` auto-sync **including `prod.yaml`**, and
that is not a hole in the production gate: they render `Application` objects
into `platform`, never a workload into `eventa-prod`. Automating them keeps
"adding a service or environment is a Git change" true for production too,
while each production child still waits for a human.

### The one place §1.3 cannot be satisfied in full

§1.3 asks for "self-heal + drift detection: manual cluster edits are reverted
to match Git" **and** for a gated production sync. Argo CD cannot give both:
`selfHeal` only exists inside `syncPolicy.automated`, and enabling it for a
production child would also auto-apply the next promotion.

§1.3 and §4.1 state the gated sync twice and in more specific words, so the
gate wins. Production keeps drift *detection* — a manual edit in `eventa-prod`
shows the Application OutOfSync — without automatic drift *reversion*; undoing
it is a human pressing sync. dev, staging and UAT self-heal as specified.

## Release names

Every child Application sets `helm.releaseName` to the **service** name while
its own `metadata.name` carries the environment:

| | |
| --- | --- |
| Application name | `eventa-prod-api` — unique, because all four environments' Applications share the `platform` namespace |
| Helm release name | `api` — so the rendered objects are `Service/api`, `Rollout/api`, … in `eventa-prod` |

This is load-bearing, not cosmetic. `web` reaches the api over the in-cluster
Service name — `API_BASE_URL: http://api/api/v1`
([deploy/charts/web/values.yaml](../deploy/charts/web/values.yaml)) — and that
file explicitly left the host for the Argo CD Application to settle. Letting
Argo CD default the release name to the Application name would produce
`Service/eventa-prod-api` and web's SSR would 503 against a name that does not
resolve, in production only, long after the change that caused it.

## What sync waves can and cannot order here

ci-cd §4.3 fixes an order: (1) the migration pre-deploy Job → (2)
api/worker/relay → (3) web. Only part of that is enforceable in this structure,
and the part that is enforced is the part that matters:

- **Enforced.** Step 1 before step 2 *inside* the api Application. The
  migration Job is a `PreSync` hook with `backoffLimit: 0`, so a failed
  migration halts that Application's sync and no api pod starts against an
  un-migrated schema.
- **Not enforced.** Ordering between separate Applications. Sync waves order
  resources within one Application; §1.3 mandates one Application per service
  per environment, so `web` and `worker` are different Applications and Argo CD
  has no ordering relationship between them.

The child Applications deliberately carry **no** `sync-wave` annotation, even
though annotating them would order the root's first bootstrap. Argo CD waits
for a wave to be *healthy* before starting the next, and a production child
never becomes healthy on its own — it is waiting for a human. A wave on the
production children would leave the wave-3 `web` Application uncreated and
invisible until someone synced the others, which is a worse failure than no
ordering at all.

What protects `worker` and `relay`, which keep typed mirrors of tables
`eventa-api` owns, is the migration contract rather than the sync order:
ci-cd §5.2 makes every migration expand-only and backward-compatible, and the
repository [README](../README.md) records as warning 3 that a migration adding
an enum value must ship **before** the services whose mirrors use it. Treat
cross-service ordering as a release-sequencing problem, not something Argo CD
will catch.

## Pruning and deletion

`prune: true` everywhere it applies, so deleting a file removes the object —
that is the other half of §1.3's "adding a service or environment is a Git
change".

No child Application carries `resources-finalizer.argocd.argoproj.io`.
Deleting `environments/prod/relay.yaml` therefore stops Argo CD managing the
relay and **leaves it running**, rather than cascading into a delete of its
workload. Removing a service from a cluster is then a deliberate second act.
The exception §7 does ask for — previews "auto-destroyed on PR close" — needs
that finalizer, and belongs on the preview ApplicationSet that does not exist
yet (below).

## Known gaps

**UAT is 3 of 5.** `deploy/charts/{checkin,worker}` have no `values-uat.yaml`;
`web`, `relay` and `api` do. Those two Applications fail with `values file does
not exist` until someone writes the file, and the reference stays in place
because that error names the fix — `ignoreMissingValueFiles` would not make
them sync, only change which error they report, and
[apps/uat.yaml](apps/uat.yaml) records why.

What each remaining file needs, by the pattern the other three charts already
set:

- `environment: uat` and an `image.tag` placeholder (ci-cd §3, §4.1).
- `externalSecret.dataFrom` at `/eventa/uat/<service>` — §5's per-environment
  path is the entire least-privilege boundary, and it is the reason these files
  cannot be skipped. `checkin` reads the api's own path, `/eventa/uat/api`,
  because it is the api process (see that chart's values).
- `config.env` hostnames for UAT. `web`'s overlay already establishes
  `uat.eventa.dev` and `api`'s establishes `api.uat.eventa.dev`.
- An `ingress.hosts` entry for `checkin`.
- `networkPolicy.egress.{postgres,redis,rabbitmq}.cidrs`. **Settle the CIDR
  scheme first.** Every one of these is a placeholder for the Terraform network
  module's data-subnet outputs (§1.1), and that module does not exist, so
  adding another opinion before it does makes the disagreement harder to
  resolve rather than easier.

  The second octet now keys the environment consistently — `10.10` dev,
  `10.20` staging, `10.30` UAT, `10.40` prod — and that part is settled. What is
  **not** settled is which subnets inside an environment hold the data tier.
  Four charts name four different answers for the same managed Postgres:

  | Environment | api / checkin | worker | relay |
  | --- | --- | --- | --- |
  | dev | `10.10.1.0/24` | `10.10.1.0/24` | `10.10.3.0/24` |
  | staging | `10.20.1.0/24` | `10.20.1.0/24` | `10.20.3.0/24` |
  | UAT | `10.30.1.0/24` | *(no overlay)* | `10.30.3.0/24` |
  | prod | `10.40.1-3.0/24` | `10.40.8.0/21` | `10.40.3-5.0/24` |

  These are not meant to differ. Both `api/values-prod.yaml` and
  `relay/values-prod.yaml` say in so many words that they list *all three
  per-AZ data subnets* because §4 gives Postgres a multi-AZ standby and
  RabbitMQ a three-node cluster — and then name different three. `worker`
  states one `/21` supernet instead, which covers `10.40.8.0-10.40.15.255` and
  so overlaps **neither** of the other two. At most one of the three can be
  right, and whichever it is, the other two silently lose their database on the
  first failover. Pick one scheme, apply it to all four charts in one change,
  and only then write the UAT overlays.

**PR previews are not implemented.** §3.1's `preview-<pr>` namespace and
ci-cd §1.1's `ApplicationSet` with a PR generator are absent on purpose; the
three blockers are written out in
[projects/eventa-preview.yaml](projects/eventa-preview.yaml), which exists to
hold that reasoning and the namespace boundary.

**`repoURL` was derived, not specified.** It is
`https://github.com/kaungkhantdev/eventa-infra.git`, taken from `git remote -v`
and rewritten from the SSH form (`git@rio.github.com:…`, a local SSH alias that
resolves on a laptop and nowhere in a cluster). Note this disagrees with the
five charts' `Chart.yaml`, which say `github.com/eventa/eventa-infra`. Fix both
to whatever the real remote becomes.

## Verifying a change

There is no cluster. Two checks, and a third that does not work here.

**1. Every chart renders the way Argo CD will render it** — same release name,
same namespace, same values file, read out of the Application manifests so the
check cannot drift from them:

```sh
cd /Users/rio/Data/rio/eventa/eventa-infra
for f in argocd/environments/*/*.yaml; do
  svc=$(basename "$f" .yaml); env=$(basename "$(dirname "$f")")
  helm template "$svc" "deploy/charts/$svc" -n "eventa-$env" \
       -f "deploy/charts/$svc/values-$env.yaml" >/dev/null \
    && echo "OK   $env/$svc" || echo "FAIL $env/$svc"
done
```

Run `helm dependency build deploy/charts/<svc>` first if `charts/` is empty —
the `file://../_library` dependency is gitignored and `Chart.lock` pins it.
Argo CD does this itself on every sync.

Expect **18 OK and 2 FAIL**: `uat/checkin` and `uat/worker`, each naming the
missing `values-uat.yaml`. Any other failure is a regression. Update these two
numbers in the same change that adds an overlay, or the next person cannot tell
a regression from a stale count.

**2. Every `path` in this tree exists, and every Application names a declared
project.** Both are easy to get wrong by renaming a directory:

```sh
find argocd -name '*.yaml' -exec grep -h '^ *path:' {} + | awk '{print $2}' | sort -u |
  while read -r p; do [ -d "$p" ] && echo "OK   $p" || echo "MISSING $p"; done

# Every project an Application names, against every project declared.
comm -23 <(grep -rh '^  project:' argocd | awk '{print $2}' | sort -u) \
         <(grep -rh '^  name:'    argocd/projects | awk '{print $2}' | sort -u)
```

The second command prints nothing when every `project:` resolves, and prints
the orphans when it does not.

**3. `kubectl apply --dry-run=client` does not work in this repo**, and not
because of anything in these manifests. It resolves every `kind` through API
discovery against a live server, so with no cluster it fails before validating
anything:

```
$ kubectl apply --dry-run=client -f argocd/root.yaml
error: error validating "argocd/root.yaml": failed to download openapi:
Get "http://localhost:8080/openapi/v2?timeout=32s": connection refused

$ kubectl apply --dry-run=client --validate=false -f argocd/root.yaml
error: unable to recognize "argocd/root.yaml":
Get "http://localhost:8080/api?timeout=32s": connection refused
```

This is the same finding the five chart READMEs already record. Offline schema
validation needs `kubeconform`, which has bundled schemas and no cluster — and
would need the Argo CD and Argo Rollouts CRD schemas supplied on top of the
Kubernetes ones. It is not installed here. Until it is, checks 1 and 2 plus the
charts' own render-time guards are the gate.

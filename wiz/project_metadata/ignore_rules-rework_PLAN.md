# ignore_rules-rework — implementation record

Brief: [`ignore_rules-rework.md`](ignore_rules-rework.md). **Implemented 2026-08-14**, on top
of [`terraform-rework_PLAN.md`](terraform-rework_PLAN.md) (same day), which it partly
supersedes. 148 tests pass and `validate.py` is clean; see *Not verified* below.

## The change

Wiz caps the number of ignore rules a tenant may hold. Exemptions are therefore **aggregated**
rather than materialised one rule each: every entry in a scope becomes one more prefix in that
scope's single rule.

```
                          BEFORE                          AFTER
env-wide     ignore-<env>-global-<name>   xN     ignore-<env>-global        x1
cluster      ignore-<env>-<cluster>-<name> xN    ignore-<env>-<cluster>     x1
per cluster  1 rule per exemption                AT MOST 2 rules, ever
fleet total  O(entries)                          #envs + #clusters  (~204 at 200 clusters)
```

A scope with no exemptions gets **no rule at all** — an empty `starts_with` list is an object
with no purpose held against the quota we are conserving.

## Decisions taken (confirmed)

| # | Decision |
|---|----------|
| 1 | **`starts_with` only.** The brief said `equals`; corrected to `starts_with`. It is the operator that still does useful work when many exemptions share one rule — `docker.io/library/redis` covers every tag without enumerating them. |
| 2 | **`expired_at` dropped entirely.** Not moved to CI enforcement. One expiry on an aggregated rule would drop every exemption in that scope simultaneously, which is not a useful operation. |
| 3 | **`operator` field removed from the schema**, rather than pinned to a one-value enum. A field with a single legal value is noise, and leaving it invites someone to try `matches_regex` and wonder why it silently matches nothing. *(Reversible — say so and it comes back as `enum: ["starts_with"]`.)* |

## What that costs

Both of these are real losses, accepted deliberately:

- **No expiry, anywhere.** An exemption lives until someone deletes its line from the YAML.
  Nothing renews it and nothing forces a review of an accepted risk. The old machinery
  (RFC3339Nano widening to end-of-day Sydney, plus a hand-rolled DST rule for runners without
  a tz database) is gone with it.
- **Prefix matching respects no boundaries.** `registry.k8s.io/pause` also covers
  `registry.k8s.io/pause-amd64`. There is a test asserting this so nobody assumes otherwise;
  the remedy is a longer prefix, not a code change.

## Files changed

**Engine** (`container-vulnerability-exemption.tf/terraform/`)

- `variables.tf` — `envs`/`clusters` carry `image_values` (a `list(string)`) instead of a list
  of exemption objects. New validation: no empty-string prefix, because a blank `starts_with`
  matches **every** image and would turn one careless entry into a fleet-wide bypass.
- `locals.tf` — collapsed from per-entry flattening to two maps of `scope => sorted prefixes`,
  filtered to scopes that have any. The `expired_at` bare-date safety net went with the field.
- `main.tf` — `env_global` / `cluster_own` are now one rule per scope; `starts_with` takes the
  whole list; no `expired_at`. Trust policy's `ignore_rules` is `compact()` of at most two,
  with explicit `contains(keys(...))` membership tests rather than `try()` so a genuine key
  mistake surfaces instead of silently dropping a rule.
- `outputs.tf` — added `ignore_rule_count`, the quantity Wiz caps, so drift toward the ceiling
  is visible in the plan. `policy_names` now reports `ignore_rules` + `exempt_image_count`.
- `examples/fleet.auto.tfvars.json` — reshaped; covers a cluster with both scopes, one with
  only the env's, and one with only its own.

**Interface** (`container-vulnerability-exemption/unikube/`)

- `schemas/exemption.defs.json` — `operator` and `expired_at` removed; `image_value` documented
  as a literal prefix.
- `scripts/common.py` — the entire expiry subsystem deleted (`expiry_timestamp`, `sydney_tz`,
  `_sydney_tz_fallback`, `_first_sunday`, `SYDNEY_TZ`, `_AEST`, `_AEDT`, and the `datetime`
  imports). `exemption_specs` loses `operator`/`expired_at`; new `image_values()` helper.
- `scripts/check_exemption.py` — `matches()` is prefix-only. This must agree with Wiz exactly,
  or CI pushes images the cluster rejects.
- `scripts/validate.py` — regex-compile check replaced by two new ones: **regex/glob-looking
  values are rejected** (under `starts_with` they match nothing and fail silently — the exact
  migration hazard), and **redundant prefixes are rejected** (a prefix already covered by a
  shorter one is dead weight in a capped rule).
- `scripts/render.py`, `scripts/mock_plan.py` — reshaped; `mock_plan` now leads with the rule
  count and shows `ignore_rules (N of max 2)` per cluster.
- All six exemption YAMLs — `operator`/`expired_at` stripped, and the regex values converted:
  `^public\.ecr\.aws/.*` → `public.ecr.aws/`, `^some\.private\.registry/repo/image:.*` →
  `some.private.registry/repo/image`.

**Tests** — 148 pass. Expiry and DST tests deleted. New: rule count tracks scopes not entries;
adding an exemption does not add a rule; at most two rules per cluster; scopes with none get
none; prefix matching covers all tags; prefix matching crosses path boundaries; nothing
carries an expiry; regex/glob/redundant values fail validation; a leftover `operator` or
`expired_at` in YAML is rejected rather than silently ignored.

**Docs** — unikube README (two-scopes section rewritten with the cost stated), engine README,
`wiz/README.md`, `project_summary.md`, and a superseded-in-part banner on
`terraform-rework_PLAN.md`.

## Not verified

- **`image_name.starts_with` accepting a multi-element list.** The whole aggregation rests on
  it. The field is already a list in the provider reference, so this is likely, but it is
  blackbox — **confirm before the first apply.** (This replaces the previous unverified
  assumption about sharing one rule id across policies, which is still also load-bearing for
  the env-global rule.)
- **The actual cap is unknown**, so nothing asserts it. `ignore_rule_count` is the only
  signal. Encode the real number once known.
- **No real `terraform` run** — no binary and no fetchable provider in this environment. HCL
  parsed with `python-hcl2`; the object graph and rule count were checked by simulating the
  `for_each` logic against the real rendered fleet. Run `terraform fmt -check` and a nonprod
  `plan` first.
- **Whether `image_name` includes the tag.** With `starts_with` it mostly stops mattering —
  a repo-only prefix covers tagged and untagged forms either way — which is part of why
  `starts_with` is the better choice here than `equals`.

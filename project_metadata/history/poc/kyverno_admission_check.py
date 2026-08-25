#!/usr/bin/env python3
"""Prove that a RENDERED cluster directory admits exactly what it claims to.

    python3 poc/kyverno_admission_check.py <rendered-cluster-dir> [--dump]
    python3 poc/kyverno_admission_check.py --all --out-dir ../container-vulnerability-exemption.kyverno/unikube

Checks the TWO-POLICY models only — what `kyverno_render_advanced.py` emits. Simple mode has
one policy and no catch-all, so there is no "accounted for" question to ask of it;
`poc/run-tests.sh` is what exercises that shape, and its point is the hole rather than the
coverage.

The counterpart of `poc/cel_check.py`, pointed at the renderer's output instead of the
hand-written POC manifests. It reads the CEL out of the SHIPPED FILES rather than rebuilding
it from `kyverno_cel.py`, so what is proved here is what `kubectl apply` would send.

THE CLAIM BEING CHECKED, in one line: **a pod is admitted if and only if every image in it is
independently admissible in that namespace.** Everything else about the design is a means to
that end, and every historic failure in this repo has been a violation of it —

    the §10.3 sneaky pod   one exempted image carrying an unsigned one into the cluster
    the two-exemption pod  two individually-approved images matching NEITHER exception
    the namespace leak     team-a's approved image riding a cluster-wide exception in team-b

so the harness enumerates pods rather than checking the cases someone thought of.

WHAT THIS DOES AND DOES NOT PROVE
  DOES  the matchConditions select the pods they are meant to, over every pod of one to three
        containers drawn from the image classes below, in three namespaces and three workload
        shapes (Pod, Deployment, CronJob).
  NOT   that Kyverno COMPILES them. That is `kubectl apply --dry-run=server`, which makes the
        real engine typecheck the real expression. Run both: this catches wrong logic, the
        dry run catches an unbound identifier. `scripts/kyverno_verify.sh` does the latter.
  NOT   that verifyImageSignatures() behaves. Signature verification is modelled as a lookup;
        only a cluster with a real registry proves that half.

Evaluation is cel-python — standard CEL with no Kyverno extensions, which is exactly why the
renderer emits `has(s.x) ? s.x : []` rather than Kyverno's own `s.?x.orValue([])`. The two
evaluate identically; the portable form is what makes this harness possible at all.
"""
from __future__ import annotations

import argparse
import itertools
import sys
from pathlib import Path

import celpy
import yaml

# This script lives in poc/ but binds to the fleet tooling in unikube/scripts/ — it renders the
# SAME exemptions tree, just into a different admission shape. Importing rather than copying is
# what keeps the two models comparable: they share common.py's config resolution, kyverno_cel's
# expression builders, and kyverno_render's header/trust/credentials primitives, so a
# difference between the rendered outputs is a difference in the MODEL and never in the
# plumbing.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "unikube" / "scripts"))

import common
import kyverno_render as base                # the FLEET renderer, for its filenames
import kyverno_render_advanced as kr

log = common.log

# A namespace no exemption in any tree may name, added to every run. It is the important one:
# whatever the config says, this is where a namespaced exemption must NOT reach, and a pod of
# two images approved in different namespaces must be denied.
FOREIGN_NAMESPACE = "unrelated-team"
SHAPES = ["pod", "deployment", "cronjob"]


def namespaces_for(specs: list[dict]) -> list[str]:
    """Every namespace this cluster's exemptions name, plus one that none of them do.

    Derived rather than hardcoded: a hardcoded list silently stops exercising a namespaced
    exemption the moment someone renames a team, and the run still prints all-ok because the
    exemption is then only ever evaluated where it is meant to fail.
    """
    seen: list[str] = []
    for spec in specs:
        for ns in spec.get("namespaces") or []:
            if ns not in seen:
                seen.append(ns)
    return seen + [FOREIGN_NAMESPACE]


# --- reading the rendered tree ------------------------------------------------
def _docs(path: Path) -> list[dict]:
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def two_policy_mode(directory: Path) -> str | None:
    """Which two-policy MODE produced this directory, or None if neither did.

    Detected from the FILENAMES rather than passed in, so the harness cannot be pointed at one
    tree while modelling the other -- the two shapes differ in exactly the way that would go
    unnoticed. None means the directory is either simple mode or not rendered at all; the
    caller decides which of those is an error, because for `--all` over a mixed fleet tree a
    simple-mode cluster is expected and for an explicit path it is a mistake.
    """
    for mode in kr.TWO_POLICY_MODES:
        if (directory / kr.FILES[mode]["policies"]).exists():
            return mode
    return None


def is_simple_mode(directory: Path) -> bool:
    """True when the fleet renderer wrote this directory. Positive evidence, not absence."""
    return (directory / base.FILES["policies"]).exists()


class Bundle:
    """The three things a rendered cluster directory says about admission."""

    def __init__(self, directory: Path):
        self.dir = directory
        self.mode = two_policy_mode(directory)
        if self.mode is not None:
            policies = directory / kr.FILES[self.mode]["policies"]
        else:
            raise SystemExit(
                f"{directory}: no two-policy manifest found "
                f"({', '.join(kr.FILES[m]['policies'] for m in kr.TWO_POLICY_MODES)}). "
                f"Simple mode is not checkable here — it has one policy and no catch-all, so "
                f"there is no 'accounted for' question to ask."
            )
        names = kr.POLICY_NAMES[self.mode]
        self.signed_name, self.catchall_name = names["signed"], names["catchall"]
        docs = {d["metadata"]["name"]: d for d in _docs(policies)}
        try:
            sig = docs[self.signed_name]
            catchall = docs[self.catchall_name]
        except KeyError as exc:
            raise SystemExit(f"{policies}: expected both {self.signed_name} and "
                             f"{self.catchall_name}, found {sorted(docs)}") from exc

        # THE INVARIANT, re-checked here and not only in the renderer's test suite: an
        # exception must never name the signature policy. If one does, nothing below is worth
        # reading, because the signature requirement is no longer a guarantee.
        self.exceptions = []
        exc_file = directory / kr.FILES[self.mode]["exceptions"]
        for exc in (_docs(exc_file) if exc_file.exists() else []):
            refs = [r["name"] for r in exc["spec"]["policyRefs"]]
            if refs != [self.catchall_name]:
                raise SystemExit(
                    f"FATAL — {exc['metadata']['name']} references {refs}. A PolicyException "
                    f"may name only {self.catchall_name}; naming the signature policy turns "
                    f"this exemption into a way to admit an unsigned self-built image."
                )
            self.exceptions.append({
                "name": exc["metadata"]["name"],
                "conditions": {m["name"]: m["expression"]
                               for m in exc["spec"]["matchConditions"]},
            })

        # The signature policy's SCOPE is where the two models differ, and the difference is
        # exactly the sort that would be modelled wrongly by accident. So each mode may only
        # use its own shape, and the wrong one is refused rather than approximated:
        #
        #   platform  plain `glob:` per prefix — static, no exemption may live inside it
        #   advanced  an `expression:` subtracting the exempted references from that scope
        refs = sig["spec"]["matchImageReferences"]
        self.signed_prefixes, self.scope_expr = [], None
        if self.mode == "platform":
            if any("glob" not in r for r in refs):
                raise SystemExit(f"{policies}: {self.signed_name} uses a non-glob "
                                 f"matchImageReferences under --platform, where that "
                                 f"scope must be static. An expression there means the "
                                 f"exemption carve-out was reintroduced.")
            self.signed_prefixes = [r["glob"][:-1] if r["glob"].endswith("*") else r["glob"]
                                    for r in refs]
        else:
            if len(refs) != 1 or "expression" not in refs[0]:
                raise SystemExit(f"{policies}: {self.signed_name} should carry exactly one "
                                 f"matchImageReferences EXPRESSION under --advanced; "
                                 f"found {refs}.")
            _env = celpy.Environment()
            self.scope_expr = _env.program(_env.compile(refs[0]["expression"]))
        self.catchall = {m["name"]: m["expression"]
                         for m in catchall["spec"]["matchConditions"]}

        # A missing credentials block is the failure that looks like success: the registry GET
        # is anonymous, 401s, and a 401 is an evaluation ERROR — which under
        # failurePolicy: Ignore means the policy is SKIPPED and the image admitted unverified.
        if sig["spec"].get("failurePolicy") == "Ignore" and not sig["spec"].get("credentials"):
            raise SystemExit(
                f"FATAL — {self.signed_name} has no spec.credentials and failurePolicy: "
                f"Ignore. On a private registry it will 401, the 401 is an evaluation error, "
                f"and the policy is skipped: it fails OPEN while reporting as healthy."
            )

        env = celpy.Environment()
        self._prog = {}
        for key, expr in list(self.catchall.items()):
            self._prog[("catchall", key)] = env.program(env.compile(expr))
        for exc in self.exceptions:
            for key, expr in exc["conditions"].items():
                self._prog[(exc["name"], key)] = env.program(env.compile(expr))

    # --- evaluation ----------------------------------------------------------
    @staticmethod
    def _object(images: list[str], namespace: str, shape: str) -> dict:
        spec = {"containers": [{"image": i} for i in images]}
        if shape == "pod":
            body = spec
        elif shape == "deployment":
            body = {"template": {"spec": spec}}
        elif shape == "cronjob":
            body = {"jobTemplate": {"spec": {"template": {"spec": spec}}}}
        else:
            raise ValueError(shape)
        return {"metadata": {"namespace": namespace}, "spec": body}

    def _in_signature_scope(self, ref: str) -> bool:
        """Is this image reference the signature policy's business?

        Under --advanced that is a CEL expression over a bare string named `ref`, and it
        subtracts the exempted references — so an exempted image is deliberately out of scope
        and falls through to the catch-all. Under --platform it is a plain prefix test.
        """
        if self.scope_expr is not None:
            return bool(self.scope_expr.evaluate({"ref": celpy.celtypes.StringType(ref)}))
        return any(ref.startswith(p) for p in self.signed_prefixes)

    def _eval(self, owner: str, key: str, obj: dict) -> bool:
        activation = celpy.json_to_cel({"object": obj})
        return bool(self._prog[(owner, key)].evaluate({"object": activation["object"]}))

    def admitted(self, images: list[str], signed: dict[str, bool],
                 namespace: str = "team-a", shape: str = "pod") -> tuple[bool, str]:
        """The admission decision this cluster directory would produce.

        Order matters and mirrors the cluster: the signature policy is unexceptable, so it is
        applied first and nothing downstream can rescue an image it denies.
        """
        obj = self._object(images, namespace, shape)
        for img in images:                           # the signature policy — UNEXCEPTABLE
            if self._in_signature_scope(img) and not signed.get(img):
                return False, f"denied by {self.signed_name} (unexceptable)"
        if not all(self._eval("catchall", k, obj) for k in self.catchall):
            return True, "every image accounted for; allowlist policy skipped"
        for exc in self.exceptions:
            if all(self._eval(exc["name"], k, obj) for k in exc["conditions"]):
                return True, f"allowlist applied; {exc['name']} admitted it"
        return False, f"denied by {self.catchall_name}"


# --- the image classes, derived from the cluster's own config -------------------
def classes_for(env: str, cluster: str) -> tuple[list[dict], dict[str, bool], list[str]]:
    """One representative image per admission class, built from the cluster's real config.

    Derived rather than hardcoded so the harness cannot drift from the tree it is checking: a
    new platform prefix or a new exemption changes these fixtures automatically, and an
    exemption removed from the YAML stops being tested as admissible.
    """
    cluster_data = common.load_yaml(common.cluster_path(env, cluster))
    global_data = common.global_for_env(env)
    signed_prefixes = common.resolve_signed_image_prefixes(cluster_data, global_data)
    platform_prefixes = common.resolve_platform_image_prefixes(cluster_data, global_data)
    specs = common.merged_exemptions(cluster_data, global_data)

    out = [
        # class 1 — self-built, compliant, SIGNED. Admissible everywhere.
        {"ref": f"{signed_prefixes[0]}app:2.0", "signed": True, "ns": None,
         "desc": "self-built, compliant, SIGNED"},
        # class 2 — self-built, UNSIGNED, under a signed prefix and NOT exempted. Admissible
        # NOWHERE in either mode: advanced only subtracts references that are actually
        # exempted, and platform subtracts none at all.
        {"ref": f"{signed_prefixes[0]}unexempted-app:1.0", "signed": False, "ns": [],
         "desc": "self-built, UNSIGNED, under a signed prefix"},
        # class 3 — platform infrastructure. Passes by scope, not by exemption.
        {"ref": f"{platform_prefixes[0]}coredns:v1.11.3", "signed": False, "ns": None,
         "desc": "platform infrastructure"},
        # class 4 — vendor, NOT exempted.
        {"ref": "docker.io/nobody/unapproved:1.0", "signed": False, "ns": [],
         "desc": "vendor, NOT exempted"},
    ]
    # class 5+ — one per exemption actually in the tree, carrying its namespace scope.
    for spec in specs:
        out.append({
            "ref": spec["value"] + ":1.0" if not spec["value"].endswith(":") else spec["value"],
            "signed": False,
            "ns": spec.get("namespaces"),          # None => admissible in every namespace
            "desc": f"EXEMPTED ({spec['name']}, "
                    f"{'cluster-wide' if not spec.get('namespaces') else ','.join(spec['namespaces'])})",
        })
    return out, {c["ref"]: c["signed"] for c in out}, namespaces_for(specs)


def admissible(klass: dict, namespace: str) -> bool:
    """Should this image, ON ITS OWN, be admitted in this namespace?

    `ns: None` means everywhere (signed self-built, platform infrastructure, a cluster-wide
    exemption); a list means only there; an empty list means nowhere.
    """
    return klass["ns"] is None or namespace in klass["ns"]


# --- the harness ---------------------------------------------------------------
def check_cluster(directory: Path, env: str, cluster: str, dump: bool = False) -> int:
    bundle = Bundle(directory)
    classes, signed, namespaces = classes_for(env, cluster)
    fails: list[str] = []

    print(f"\n=== {env}/{cluster} — {len(classes)} image classes, "
          f"{len(bundle.exceptions)} exception(s), namespaces {namespaces} ===")

    print("\n--- each class on its own, in each namespace ---")
    for k in classes:
        for ns in namespaces:
            want = admissible(k, ns)
            got, why = bundle.admitted([k["ref"]], signed, ns)
            ok = got == want
            if not ok:
                fails.append(f"{k['desc']} in {ns}")
            print(f"  {k['desc'][:46]:46} {ns:11} "
                  f"{'ADMIT' if got else 'BLOCK'} want {'ADMIT' if want else 'BLOCK'} "
                  f"{'ok' if ok else '<<< MISMATCH'}  {why if not ok else ''}")

    print(f"\n--- exhaustive: every pod of 1-3 images, {len(namespaces)} namespaces, "
          f"{len(SHAPES)} shapes ---")
    print("    A pod must be admitted IF AND ONLY IF every image in it is independently")
    print("    admissible in that namespace. This is the sneaky-pod invariant.")
    total = bad = 0
    for n in (1, 2, 3):
        for combo in itertools.product(range(len(classes)), repeat=n):
            for ns in namespaces:
                for shape in SHAPES:
                    total += 1
                    want = all(admissible(classes[i], ns) for i in combo)
                    got, why = bundle.admitted([classes[i]["ref"] for i in combo],
                                               signed, ns, shape)
                    if got != want:
                        bad += 1
                        if bad <= 10:
                            names = " + ".join(classes[i]["desc"] for i in combo)
                            print(f"    MISMATCH [{ns}/{shape}] {names}: "
                                  f"got {'ADMIT' if got else 'BLOCK'}, "
                                  f"want {'ADMIT' if want else 'BLOCK'} ({why})")
    if bad:
        fails.append(f"{bad} exhaustive mismatches")
    print(f"    {total - bad}/{total} correct")

    print("\n--- the prefix allowlist must be identical in every expression ---")
    lists = {"allowlist policy": _prefix_set(bundle.catchall)}
    for exc in bundle.exceptions:
        found = _prefix_set(exc["conditions"])
        # An exception with NO bound prefix list is not drift — it is the platform-namespace
        # object, whose only clause is a namespace test. It deliberately carries no image or
        # prefix vocabulary at all, which is precisely why it cannot widen anyone's guard.
        if not found:
            print(f"    {exc['name']:42} no prefix list (namespace-scoped)  ok")
            continue
        lists[exc["name"]] = found
    reference = lists["allowlist policy"]
    for name, found in lists.items():
        same = found == reference
        if not same:
            fails.append(f"prefix list differs in {name}")
            print(f"    only here: {sorted(found - reference)}  "
                  f"missing: {sorted(reference - found)}")
        print(f"    {name:42} {len(found)} prefixes  {'ok' if same else '<<< MISMATCH'}")

    if dump:
        for name, expr in bundle.catchall.items():
            print(f"\n--- catchall/{name} ---\n{expr}")
        for exc in bundle.exceptions:
            for name, expr in exc["conditions"].items():
                print(f"\n--- {exc['name']}/{name} ---\n{expr}")

    if fails:
        print(f"\nFAILURES in {env}/{cluster}: {fails}")
        return 1
    print(f"\nOK — {env}/{cluster} admits exactly what its exemptions describe.")
    return 0


def _prefix_set(conditions: dict[str, str]) -> set[str]:
    """The bound prefix list out of a rendered expression, as a set.

    Extracted TEXTUALLY and on purpose: the whole point is to catch two expressions that were
    generated from what should have been one list and are no longer the same. Rebuilding them
    from config would compare the config against itself.
    """
    import re
    found: set[str] = set()
    for expr in conditions.values():
        for block in re.findall(r"\[\[(.*?)\]\]", expr, flags=re.S):
            found |= set(re.findall(r"'([^']+)'", block))
    return found


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("directory", nargs="?", type=Path,
                    help="a rendered cluster directory, e.g. <out>/nonprod/wizn02")
    ap.add_argument("--all", action="store_true",
                    help="check every cluster in the tree under --out-dir")
    ap.add_argument("--out-dir", type=Path, default=kr.DEFAULT_OUT_DIR)
    ap.add_argument("--dump", action="store_true", help="also print the extracted expressions")
    common.debug_arg(ap)
    args = ap.parse_args(argv)
    common.setup_logging(args.debug)

    rc = 0
    if args.all:
        for env, cluster, _ in common.iter_cluster_files():
            d = kr.cluster_dir(args.out_dir, f"{env}/{cluster}")
            if not d.is_dir():
                print(f"SKIP {env}/{cluster}: {d} not rendered")
                continue
            # A mixed fleet tree is the normal case now: most clusters render under the fleet
            # renderer and only the bake-off ones under this model. Skipping those is not
            # leniency -- simple mode has ONE policy and no catch-all, so the question this
            # harness asks ("is every image accounted for?") does not exist there. It is
            # skipped on POSITIVE evidence (10-ivpol.yaml is present), never on absence, so a
            # directory that is simply missing its manifests still fails.
            if two_policy_mode(d) is None and is_simple_mode(d):
                print(f"SKIP {env}/{cluster}: simple mode (one policy, no catch-all)")
                continue
            rc |= check_cluster(d, env, cluster, args.dump)
    elif args.directory:
        # <out-dir>/<env>/<cluster>/policy-exception -> (env, cluster). Accepts the cluster
        # directory too, so both `.../wizn02` and `.../wizn02/policy-exception` work.
        d = args.directory
        if d.name == kr.base.CLUSTER_SUBDIR:
            d = d.parent
        args.directory = kr.cluster_dir(d.parent.parent, f"{d.parent.name}/{d.name}")
        env, cluster = d.parent.name, d.name
        rc = check_cluster(args.directory, env, cluster, args.dump)
    else:
        ap.error("give a cluster directory, or --all")
    return rc


if __name__ == "__main__":
    sys.exit(main())

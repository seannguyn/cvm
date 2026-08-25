#!/usr/bin/env python3
"""Prove that 50-platform-admission.yaml and 51-appteam-exception.yaml admit exactly what they
claim. Run from container-vulnerability-exemption/poc/

    python3 cel_check.py            # verdict table
    python3 cel_check.py --dump     # plus the expressions it extracted

Reads the CEL out of the SHIPPED MANIFESTS — it does not rebuild it — so the thing proved here
is the thing applied to the cluster. Evaluation is cel-python, the same evaluator
unikube/tests/test_kyverno_cel.py uses; it is standard CEL with no Kyverno extensions, which is
why the manifests deliberately avoid the optional-types `?.`/`orValue` idiom.

WHAT THIS DOES AND DOES NOT PROVE
  DOES  the matchConditions select the pods they are meant to, over every pod of one to three
        containers drawn from six image classes, plus the shape variants (Deployment, CronJob)
        and namespace isolation.
  NOT   that Kyverno compiles them. That is `kubectl apply --dry-run=server`, which makes the
        real engine typecheck the real expression. Run both: this catches wrong logic, the
        dry run catches an unbound identifier.
  NOT   that verifyImageSignatures() behaves. Signature verification is modelled as a lookup
        here; only a cluster with a real registry proves that half.
"""
import itertools
import sys
from pathlib import Path

import celpy
import yaml

PLATFORM_FILE = Path("50-platform-admission.yaml")
EXC_FILE = Path("51-appteam-exception.yaml")

ECR = "891377217246.dkr.ecr.ap-southeast-2.amazonaws.com"
EKS = "602401143452.dkr.ecr.ap-southeast-2.amazonaws.com"
SOE = f"{ECR}/soe-demo/"      # env.sh's SOE_PREFIX

# The six image classes. `signed` matters only under the SOE prefix, where Policy A applies.
CLASSES = {
    1: (f"{SOE}app:2.0", True, "self-built, compliant, SIGNED"),
    2: (f"{SOE}app:1.0", False, "self-built, non-compliant, UNSIGNED, under soe/"),
    3: (f"{ECR}/unverified/app:3.0", False, "non-compliant self-built, EXEMPTED"),
    4: (f"{ECR}/vendor-demo/other:2.0", False, "vendor, NOT exempted"),
    5: (f"{ECR}/vendor-demo/tool:3.0", False, "vendor, EXEMPTED"),
    6: (f"{EKS}/eks/coredns:v1.11.3", False, "platform infrastructure"),
}
EXPECT = {1: True, 2: False, 3: True, 4: False, 5: True, 6: True}
SIGNED = {ref: sig for ref, sig, _ in CLASSES.values()}
TEAM_NS = "demo"              # env.sh's DEMO_NS


def _docs(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def load():
    """Pull the three expressions and the signature policy's glob out of the manifests."""
    plat = {d["metadata"]["name"]: d for d in _docs(PLATFORM_FILE)}
    sig = plat["platform-soe-signature"]
    catchall = plat["platform-image-allowlist"]
    exc = _docs(EXC_FILE)[0]

    # The invariant, checked here as well as in the renderer's test suite: an exception must
    # never name the signature policy. If it does, nothing below is worth reading.
    refs = [r["name"] for r in exc["spec"]["policyRefs"]]
    assert refs == ["platform-image-allowlist"], \
        f"FATAL: exception references {refs}; it must reference only the allowlist policy"

    globs = [r["glob"] for r in sig["spec"]["matchImageReferences"] if "glob" in r]
    # A LIST now: env.sh has two self-built registries (soe-demo/, soe-team2/), matching what
    # run-advanced-tests.sh exercises in cases 13-14. Still globs, never an expression -- an
    # expression here would mean the exemption carve-out came back and the signature policy
    # stopped being static.
    assert globs and all(g.endswith("*") for g in globs), globs
    conds = {m["name"]: m["expression"] for m in catchall["spec"]["matchConditions"]}
    exc_conds = {m["name"]: m["expression"] for m in exc["spec"]["matchConditions"]}
    return [g[:-1] for g in globs], conds, exc_conds


SIG_PREFIXES, CATCH, EXC = load()
ENV = celpy.Environment()
PROG = {k: ENV.program(ENV.compile(v))
        for k, v in list(CATCH.items()) + list(EXC.items())}


def pod(images, ns=TEAM_NS, shape="pod"):
    """An admission object in one of the three shapes the CEL ternary has to survive."""
    spec = {"containers": [{"image": i} for i in images]}
    if shape == "pod":
        body = spec
    elif shape == "deployment":
        body = {"template": {"spec": spec}}
    elif shape == "cronjob":
        body = {"jobTemplate": {"spec": {"template": {"spec": spec}}}}
    else:
        raise ValueError(shape)
    return {"metadata": {"namespace": ns}, "spec": body}


def ev(name, obj):
    act = celpy.json_to_cel({"object": obj})
    return bool(PROG[name].evaluate({"object": act["object"]}))


def admitted(images, ns=TEAM_NS, shape="pod"):
    obj = pod(images, ns, shape)
    # Policy A — signature. Plain glob on the SOE prefix; UNEXCEPTABLE, so it is evaluated
    # first and no exception can rescue an image it denies.
    for img in images:
        if any(img.startswith(p) for p in SIG_PREFIXES) and not SIGNED.get(img, False):
            return False, "denied by platform-soe-signature (unexceptable)"
    # Policy B — allowlist.
    if not all(ev(n, obj) for n in CATCH):
        return True, "every image accounted for; allowlist policy skipped"
    if all(ev(n, obj) for n in EXC):
        return True, "allowlist applied; app-team exception admitted it"
    return False, "denied by platform-image-allowlist"


fails = []


def check(label, got, want, detail=""):
    good = got == want
    if not good:
        fails.append(label)
    print(f"  {label:52} {'ADMIT' if got else 'BLOCK':5} want {'ADMIT' if want else 'BLOCK':5}"
          f" {'ok' if good else '<<< MISMATCH':12} {detail}")


print("=== each image class on its own ===")
for k, (ref, _, desc) in sorted(CLASSES.items()):
    got, why = admitted([ref])
    check(f"class {k}: {desc}", got, EXPECT[k], why)

print("\n=== the pods that decide the design ===")
CASES = [
    ([6], True, "a pure platform pod — coredns must schedule"),
    ([6, 1], True, "platform sidecar + signed app"),
    ([6, 2], False, "a platform image CANNOT carry an unsigned self-built one"),
    ([6, 5], True, "platform sidecar + approved vendor image"),
    ([1, 1, 2], False, "signed + signed + UNSIGNED self-built"),
    ([1, 1, 3], True, "signed + signed + approved non-compliant"),
    ([4, 1, 5], False, "one unapproved vendor image is enough to deny"),
    ([5, 2], False, "an approved vendor image CANNOT carry an unsigned self-built one"),
    ([5, 3], True, "two approved images in one pod both match"),
    ([3, 4], False, "approved + unapproved"),
]
for combo, want, label in CASES:
    got, why = admitted([CLASSES[c][0] for c in combo])
    check(f"{combo} {label}", got, want, why)

# The namespaces come from env.sh (DEMO_NS / DEMO_NS2 / FOREIGN_NS), so this file and
# run-platform-tests.sh cannot drift apart on the one axis 30/31 has no vocabulary for.
print("\n=== namespace isolation: this exemption must not carry a foreign namespace ===")
for ns, want in [(TEAM_NS, True), (f"{TEAM_NS}-uat", True), ("other-team", False),
                 ("default", False)]:
    got, why = admitted([CLASSES[5][0]], ns=ns)
    check(f"approved vendor image in namespace {ns!r}", got, want, why)

print("\n=== workload shapes: the pod spec is not always at object.spec ===")
for shape in ("pod", "deployment", "cronjob"):
    got, _ = admitted([CLASSES[5][0]], shape=shape)
    check(f"approved vendor image as a {shape}", got, True)
    got, _ = admitted([CLASSES[4][0]], shape=shape)
    check(f"unapproved vendor image as a {shape}", got, False)

print("\n=== exhaustive: every pod of 1-3 containers over the six classes ===")
bad = 0
total = 0
for n in (1, 2, 3):
    for combo in itertools.product(sorted(CLASSES), repeat=n):
        total += 1
        want = all(EXPECT[c] for c in combo)
        got, _ = admitted([CLASSES[c][0] for c in combo])
        if got != want:
            bad += 1
            if bad <= 10:
                print(f"    MISMATCH {combo}: got {'ADMIT' if got else 'BLOCK'}, "
                      f"want {'ADMIT' if want else 'BLOCK'}")
print(f"  {total - bad}/{total} correct")
if bad:
    fails.append(f"{bad} exhaustive mismatches")

print("\n=== the prefix allowlist must be identical in both files ===")
import re
plat_list = set(re.findall(r"'([^']+/)'", CATCH["not-already-accounted-for"]))
exc_list = set(re.findall(r"'([^']+/)'", EXC["every-other-image-is-accounted-for"]))
same = plat_list == exc_list
if not same:
    fails.append("prefix lists differ")
    print(f"  only in platform: {sorted(plat_list - exc_list)}")
    print(f"  only in exception: {sorted(exc_list - plat_list)}")
print(f"  {len(plat_list)} prefixes, identical in both files: {'ok' if same else '<<< MISMATCH'}")

if "--dump" in sys.argv:
    for name, src in list(CATCH.items()) + list(EXC.items()):
        print(f"\n--- {name} ---\n{src}")

print("\n" + ("ALL CHECKS PASSED" if not fails else f"FAILURES: {fails}"))
sys.exit(1 if fails else 0)

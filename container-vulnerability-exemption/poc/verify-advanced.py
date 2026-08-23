#!/usr/bin/env python3
"""Prove §11's two policies admit exactly the matrix §11.1 states. Run from
container-vulnerability-exemption/poc/ after `source env.sh` and §11.6.

    python3 verify-advanced.py            # verdict table
    python3 verify-advanced.py --dump     # plus the expressions it extracted

Reads the CEL out of the GENERATED MANIFESTS -- it does not rebuild it -- so what is proved here
is what gets applied. Evaluation is cel-python: standard CEL with no Kyverno extensions, which is
why the generator avoids the optional-types `?.`/`orValue` idiom.

WHAT THIS PROVES, AND WHAT IT CANNOT
  DOES  the matchConditions and the scope expression select the pods they are meant to, over every
        pod of one to three containers drawn from six image classes, in all three workload shapes.
  NOT   that Kyverno COMPILES them -- that is `kubectl apply --dry-run=server`, which runs the real
        typechecker. This catches wrong logic; the dry run catches an unbound identifier.
  NOT   that verifyImageSignatures() behaves. Signature state is modelled from the fixture table
        here; only a cluster with a real registry proves that half. That is run-advanced-tests.sh.
"""
import itertools
import os
import re
import sys
from pathlib import Path

try:
    import celpy
except ImportError:                                   # the Python 3.9 google-re2 trap, see §11.7
    raise SystemExit(
        "celpy is not installed.\n"
        "  Install from the repo's requirements.txt, NOT with a bare `pip install cel-python`:\n"
        "      python3 -m pip install -r ../unikube/scripts/requirements.txt\n"
        "  cel-python pulls in google-re2, which dropped cp39 wheels while still shipping an\n"
        "  sdist -- so on Python 3.9 pip tries to compile re2 and abseil from source and fails\n"
        "  with \"'absl/strings/string_view.h' file not found\". requirements.txt caps it."
    )
import yaml

POLICIES = Path("30-ivpol-advanced.yaml")
EXCEPTIONS = Path("31-polex-advanced.yaml")

SIG_POLICY = "soe-notary-signed"
CATCHALL = "deny-unverified-images"


def env(name):
    v = os.environ.get(name)
    if not v:
        sys.exit(f"{name} is not set -- run `source env.sh` first (and §11.5 for SOE_PREFIX2)")
    return v


ECR = env("ECR")
PREFIXES = [env("SOE_PREFIX"), env("SOE_PREFIX2")]
IMG_10, IMG_20, IMG_30 = env("IMG_10"), env("IMG_20"), env("IMG_30")
IMG_T2 = env("IMG_T2")
VENDOR_A, VENDOR_X = env("VENDOR_A"), env("VENDOR_X")
EXEMPT = [IMG_30, VENDOR_A, env("VENDOR_B")]

# class -> (image, is-signed, description). `signed` matters only where the signature policy
# is in scope; elsewhere it is ignored, exactly as on the cluster.
CLASSES = {
    1: (IMG_20, True, "self-built, compliant, SIGNED"),
    2: (IMG_10, False, "self-built, non-compliant, UNSIGNED"),
    3: (IMG_30, False, "self-built, non-compliant, EXEMPTED"),
    4: (VENDOR_X, False, "vendor, NOT exempted"),
    5: (VENDOR_A, False, "vendor, EXEMPTED"),
    6: (IMG_T2, True, "SECOND self-built registry, SIGNED"),
}
EXPECT = {1: True, 2: False, 3: True, 4: False, 5: True, 6: True}
SIGNED = {ref: sig for ref, sig, _ in CLASSES.values()}


def docs(p):
    if not p.exists():
        sys.exit(f"{p} not found -- generate it in §11.6 first")
    return [d for d in yaml.safe_load_all(p.read_text()) if d]


def load():
    pol = {d["metadata"]["name"]: d for d in docs(POLICIES)}
    for want in (SIG_POLICY, CATCHALL):
        if want not in pol:
            sys.exit(f"{POLICIES} does not contain {want}")

    # THE INVARIANT, checked before anything else: no exception may name the signature policy.
    # If one does, nothing below this line is worth reading.
    excs = docs(EXCEPTIONS)
    bad = [(d["metadata"]["name"], r["name"]) for d in excs
           for r in d["spec"]["policyRefs"] if r["name"] != CATCHALL]
    if bad:
        sys.exit(f"FATAL: exception(s) reference a policy other than {CATCHALL}: {bad}\n"
                 f"  An exception naming the signature policy re-opens §10.3.")

    mir = pol[SIG_POLICY]["spec"]["matchImageReferences"]
    scope = next((e["expression"] for e in mir if "expression" in e), None)
    if scope is None:
        sys.exit(f"{SIG_POLICY} uses a plain glob, not a scope expression -- class 3 cannot "
                 f"be admitted. See §11.3(a).")
    catch = {m["name"]: m["expression"]
             for m in pol[CATCHALL]["spec"]["matchConditions"]}
    # EVERY exception, not just the first. Each one's SELECT names only its OWN image, so a pod
    # is admitted when ANY exception matches it -- testing one would silently pass pods that no
    # exception actually covers, and fail pods a sibling covers.
    econds = {d["metadata"]["name"]: {m["name"]: m["expression"]
                                      for m in d["spec"]["matchConditions"]} for d in excs}
    return scope, catch, econds, len(excs)


SCOPE_SRC, CATCH, ECONDS, N_EXC = load()
ENV = celpy.Environment()
PROG = {f"catch/{k}": ENV.program(ENV.compile(v)) for k, v in CATCH.items()}
PROG.update({f"{exc}/{k}": ENV.program(ENV.compile(v))
             for exc, conds in ECONDS.items() for k, v in conds.items()})
SCOPE = ENV.program(ENV.compile(SCOPE_SRC))

_CACHE = {}


def _obj(imgs, shape):
    spec = {"containers": [{"image": i} for i in imgs]}
    body = {"pod": spec,
            "deployment": {"template": {"spec": spec}},
            "cronjob": {"jobTemplate": {"spec": {"template": {"spec": spec}}}}}[shape]
    return {"metadata": {"namespace": "demo"}, "spec": body}


def ev(name, imgs, shape):
    key = (name, tuple(sorted(set(imgs))), shape)
    if key not in _CACHE:
        act = celpy.json_to_cel({"object": _obj(imgs, shape)})
        _CACHE[key] = bool(PROG[name].evaluate({"object": act["object"]}))
    return _CACHE[key]


def in_signature_scope(image):
    """Evaluate the REAL scope expression, with `ref` bound as Kyverno binds it (§11.4)."""
    key = ("scope", image)
    if key not in _CACHE:
        _CACHE[key] = bool(SCOPE.evaluate({"ref": celpy.celtypes.StringType(image)}))
    return _CACHE[key]


def admitted(imgs, shape="pod"):
    # Policy 1 -- signature, UNEXCEPTABLE, so evaluated first and nothing can rescue it.
    for i in imgs:
        if in_signature_scope(i) and not SIGNED.get(i, False):
            return False, f"denied by {SIG_POLICY} (unexceptable)"
    # Policy 2 -- catch-all.
    if not all(ev(f"catch/{n}", imgs, shape) for n in CATCH):
        return True, "every image owned by the signature policy; catch-all skipped"
    # ANY exception whose clauses all hold skips the catch-all for this resource.
    for exc, conds in ECONDS.items():
        if all(ev(f"{exc}/{n}", imgs, shape) for n in conds):
            return True, f"catch-all applied; {exc} admitted it"
    return False, f"denied by {CATCHALL}"


fails = []


def check(label, got, want, note=""):
    ok = got == want
    if not ok:
        fails.append(label)
    print(f"  {label:52} {'ADMIT' if got else 'BLOCK':5} want {'ADMIT' if want else 'BLOCK':5}"
          f" {'ok' if ok else '<<< MISMATCH':12} {note}")


print(f"policies: {POLICIES}   exceptions: {EXCEPTIONS} ({N_EXC})")
print(f"scope:    {SCOPE_SRC[:96]}{'...' if len(SCOPE_SRC) > 96 else ''}\n")

print("== each image class on its own ==")
for k, (ref, _, d) in sorted(CLASSES.items()):
    got, why = admitted([ref])
    check(f"class {k}: {d}", got, EXPECT[k], why)

print("\n== the pods that decide the design ==")
CASES = [
    ([1, 1, 2], False, "signed + signed + UNSIGNED self-built"),
    ([1, 1, 3], True, "signed + signed + approved non-compliant"),
    ([4, 1, 5], False, "one unapproved vendor image is enough to deny"),
    ([3, 2], False, "THE §10.3 SNEAKY POD -- exempted carrying an unsigned self-built"),
    ([5, 2], False, "approved vendor cannot carry an unsigned self-built"),
    ([1, 5], True, "signed app + approved vendor sidecar"),
    ([3, 5], True, "two approved images in one pod both match"),
    ([1, 6], True, "TWO self-built registries, both signed"),
    ([6, 2], False, "registry 2 signed + registry 1 unsigned"),
]
for combo, want, label in CASES:
    got, why = admitted([CLASSES[c][0] for c in combo])
    check(f"{combo} {label}", got, want, why)

print("\n== workload shapes: the pod spec is not always at object.spec ==")
for shape in ("pod", "deployment", "cronjob"):
    check(f"approved vendor image as a {shape}", admitted([CLASSES[5][0]], shape)[0], True)
    check(f"unapproved vendor image as a {shape}", admitted([CLASSES[4][0]], shape)[0], False)

print("\n== exhaustive: every pod of 1-3 containers over the six classes ==")
bad = total = 0
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

print("\n== each exception SELECTs only its OWN image ==")
# THE REGRESSION TEST FOR A REAL BUG. The generator once built SELECT from the whole exemption
# list, so all three exceptions were byte-identical. Admission was unaffected -- which is why
# 258/258 still passed -- but two things silently broke: the PolicyReport `skip` row named an
# arbitrary exception, and deleting an expired exception changed nothing, because its siblings
# still selected the image it was carrying. Expiry stopped working and nothing said so.
sel_imgs = {e: set(re.findall(r"'([^']+:[^']+)'", c["selects-this-exemption"]))
            for e, c in ECONDS.items()}
distinct = len({frozenset(v) for v in sel_imgs.values()}) == len(sel_imgs)
for e, v in sorted(sel_imgs.items()):
    print(f"  {e:18} selects {sorted(x.split('/')[-1] for x in v)}")
if not distinct:
    fails.append("exceptions share a SELECT list")
print(f"  {len(sel_imgs)} exceptions, each selecting a distinct image: "
      f"{'ok' if distinct else '<<< MISMATCH -- deleting one would not expire it'}")

print("\n== deleting one exception withdraws exactly its own authorisation ==")
# What actually happens when an exemption expires: the object is deleted, and the image it
# carried must stop being admitted -- while the other exemptions keep working.
_saved = dict(ECONDS)
for gone, img_class in [("allow-app-30", 3), ("allow-vendor-a", 5)]:
    ECONDS.clear(); ECONDS.update({k: v for k, v in _saved.items() if k != gone})
    _CACHE.clear()
    got, why = admitted([CLASSES[img_class][0]])
    check(f"{gone} deleted -> its image", got, False, why)
    other = 5 if img_class == 3 else 3
    got, why = admitted([CLASSES[other][0]])
    check(f"{gone} deleted -> a DIFFERENT exemption's image", got, True, why)
ECONDS.clear(); ECONDS.update(_saved); _CACHE.clear()

print("\n== the prefix list must be identical in all three expressions ==")
sets = {name: set(re.findall(r"'([^']+/)'", src))
        for name, src in ([("scope", SCOPE_SRC),
                           ("catch-all", next(iter(CATCH.values())))]
                          + [(f"guard/{e}", c["every-other-image-is-accounted-for"])
                             for e, c in ECONDS.items()])}
same = len({frozenset(v) for v in sets.values()}) == 1
if not same:
    fails.append("prefix lists differ")
    for n, v in sets.items():
        print(f"    {n}: {sorted(v)}")
print(f"  {len(sets['scope'])} prefixes, identical everywhere: {'ok' if same else '<<< MISMATCH'}")

if "--dump" in sys.argv:
    print("\n--- signature scope ---\n" + SCOPE_SRC)
    for n, s in list(CATCH.items()) + list(ECONDS.items()):
        print(f"\n--- {n} ---\n{s}")

print("\n" + ("ALL PASSED" if not fails else f"FAILURES: {fails}"))
sys.exit(1 if fails else 0)

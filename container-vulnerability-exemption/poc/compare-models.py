#!/usr/bin/env python3
"""Run BOTH admission models through the SAME 16 cases, offline. The bake-off's dry run.

    python3 compare-models.py          # exit 0 iff both models pass all 16

    30/31  poc/30-ivpol-advanced.yaml + 31-polex-advanced.yaml   (demo.md §11)
    50/51  poc/50-platform-admission.yaml + 51-appteam-exception.yaml

WHY THIS EXISTS. A comparison is only evidence if both sides face an identical matrix over an
identical image population. The first attempt at pointing run-advanced-tests.sh at 50/51
scored 8/16 -- and every one of the 8 "passes" was a BLOCK case, because none of the harness's
images existed in 50/51's fixture world. A policy that denied all input would have scored the
same. This script catches that class of mistake before a cluster run does.

THE ONE FIXTURE THAT DIFFERS, and it is a finding rather than a fudge:

    class 3, "non-compliant self-built build, admitted by exemption"
      30/31  soe-demo/app:3.0    exempted IN PLACE, carved out of the signature policy's scope
      50/51  unverified/app:3.0  same bytes, RELOCATED out of that scope, exempted there

50/51 cannot express the first and will not: the signed prefix is an ACL boundary, so an
unsigned image under it is meant to be impossible rather than merely disallowed. Both models
admit the non-compliant build by exemption; they differ in the route. Read case 3 that way.

WHAT THIS DOES AND DOES NOT PROVE
  DOES  the matchConditions select the pods they are meant to, for both models, over the §11.1
        matrix plus the five cases only 50/51 can express.
  NOT   that Kyverno COMPILES either. That is `kubectl apply --dry-run=server`.
  NOT   that verifyImageSignatures() behaves -- signing is modelled as set membership here.
        Only run-advanced-tests.sh / run-platform-tests.sh on a live cluster prove that half.
"""
import sys, yaml, celpy

ECR = "891377217246.dkr.ecr.ap-southeast-2.amazonaws.com"
F = dict(
    IMG_10=f"{ECR}/soe-demo/app:1.0",      # self-built, unsigned
    IMG_20=f"{ECR}/soe-demo/app:2.0",      # self-built, SIGNED
    IMG_30=f"{ECR}/soe-demo/app:3.0",      # non-compliant, exempted IN PLACE   (model A only)
    IMG_30U=f"{ECR}/unverified/app:3.0",   # same content, RELOCATED + exempted (model B only)
    IMG_T2=f"{ECR}/soe-team2/app:1.0",     # second self-built registry, SIGNED
    VENDOR_A=f"{ECR}/vendor-demo/tool:3.0",
    VENDOR_B=f"{ECR}/vendor-demo/sidecar:1.0",
    VENDOR_X="public.ecr.aws/docker/library/busybox:1.36",
    COREDNS="602401143452.dkr.ecr.ap-southeast-2.amazonaws.com/eks/coredns:v1.11.3",
)
SIGNED = {F["IMG_20"], F["IMG_T2"]}
DEMO_NS = "demo"

env = celpy.Environment()
def prog(e): return env.program(env.compile(e))


class Model:
    def __init__(self, name, policy_file, exc_file, sig_name, catch_name, img30):
        self.name, self.img30 = name, img30
        P = {d["metadata"]["name"]: d
             for d in yaml.safe_load_all(open(policy_file).read()) if d and "metadata" in d}
        sig, catch = P[sig_name], P[catch_name]
        refs = sig["spec"]["matchImageReferences"]
        # 30/31 scopes the signature policy with an EXPRESSION (exemptions carved out);
        # 50/51 with plain GLOBS (static). Both shapes are modelled, which is the point.
        self.sig_expr = prog(refs[0]["expression"]) if "expression" in refs[0] else None
        self.sig_globs = [r["glob"][:-1] for r in refs if "glob" in r]
        self.catch = [prog(m["expression"]) for m in catch["spec"]["matchConditions"]]
        self.excs = []
        for d in (x for x in yaml.safe_load_all(open(exc_file).read()) if x):
            assert [r["name"] for r in d["spec"]["policyRefs"]] == [catch_name], \
                f"{d['metadata']['name']} must reference only {catch_name}"
            self.excs.append((d["metadata"]["name"],
                              [prog(m["expression"]) for m in d["spec"]["matchConditions"]]))

    def _in_sig_scope(self, ref):
        if self.sig_expr is not None:
            return bool(self.sig_expr.evaluate({"ref": celpy.celtypes.StringType(ref)}))
        return any(ref.startswith(p) for p in self.sig_globs)

    def admitted(self, images, shape="pod", ns=DEMO_NS):
        spec = {"containers": [{"image": i} for i in images]}
        body = {"pod": spec,
                "deployment": {"template": {"spec": spec}},
                "cronjob": {"jobTemplate": {"spec": {"template": {"spec": spec}}}}}[shape]
        o = {"metadata": {"namespace": ns}, "spec": body}
        act = celpy.json_to_cel({"object": o})
        ev = lambda p: bool(p.evaluate({"object": act["object"]}))
        for img in images:                                  # Policy A — unexceptable
            if self._in_sig_scope(img) and img not in SIGNED:
                return False, "denied by the signature policy (unexceptable)"
        if not all(ev(p) for p in self.catch):
            return True, "catch-all skipped (every image already accounted for)"
        for n, clauses in self.excs:
            if all(ev(p) for p in clauses):
                return True, f"admitted by {n}"
        return False, "denied by the catch-all"


# The §11.1 matrix, verbatim. `30` is the fixture that differs between models -- see below.
CASES = [
    (1,  "ADMIT", "class 1  self-built, signed",                     ["IMG_20"], "pod"),
    (2,  "BLOCK", "class 2  self-built, unsigned",                   ["IMG_10"], "pod"),
    (3,  "ADMIT", "class 3  self-built, unsigned, EXEMPTED",         ["30"], "pod"),
    (4,  "BLOCK", "class 4  vendor, not exempted",                   ["VENDOR_X"], "pod"),
    (5,  "ADMIT", "class 5  vendor, EXEMPTED",                       ["VENDOR_A"], "pod"),
    (6,  "BLOCK", "1,1,2    one unsigned self-built image",          ["IMG_20","IMG_20","IMG_10"], "pod"),
    (7,  "ADMIT", "1,1,3    signed + signed + approved",             ["IMG_20","IMG_20","30"], "pod"),
    (8,  "BLOCK", "4,1,5    one unapproved vendor image",            ["VENDOR_X","IMG_20","VENDOR_A"], "pod"),
    (9,  "BLOCK", "3,2      THE SNEAKY POD",                         ["30","IMG_10"], "pod"),
    (10, "BLOCK", "5,2      approved vendor + unsigned self-built",  ["VENDOR_A","IMG_10"], "pod"),
    (11, "ADMIT", "1,5      signed app + approved vendor sidecar",   ["IMG_20","VENDOR_A"], "pod"),
    (12, "ADMIT", "3,5      two approved images in one pod",         ["30","VENDOR_A"], "pod"),
    (13, "ADMIT", "1,6      two registries, both signed",            ["IMG_20","IMG_T2"], "pod"),
    (14, "BLOCK", "6,2      registry 2 signed + registry 1 unsigned",["IMG_T2","IMG_10"], "pod"),
    (15, "ADMIT", "deployment with an EXEMPTED vendor image",        ["VENDOR_A"], "deployment"),
    (16, "BLOCK", "cronjob with an UNAPPROVED vendor image",         ["VENDOR_X"], "cronjob"),
]

MODELS = [
    Model("30/31 advanced", "30-ivpol-advanced.yaml", "31-polex-advanced.yaml",
          "soe-notary-signed", "deny-unverified-images", "IMG_30"),
    Model("50/51 platform", "50-platform-admission.yaml", "51-appteam-exception.yaml",
          "platform-soe-signature", "platform-image-allowlist", "IMG_30U"),
]

rc = 0
for m in MODELS:
    print(f"\n=== {m.name}   (class 3 fixture: {m.img30} = {F[m.img30]}) ===")
    p = f = 0
    for n, want, label, keys, shape in CASES:
        imgs = [F[m.img30 if k == "30" else k] for k in keys]
        got, why = m.admitted(imgs, shape)
        g = "ADMIT" if got else "BLOCK"
        ok = g == want
        p, f = p + ok, f + (not ok)
        print(f"  {n:>2}  {'ok  ' if ok else 'FAIL'}  {g:6} {label}" + ("" if ok else f"   <- {why}"))
    print(f"  RESULT  {p}/{p+f} passed")
    rc |= (f != 0)

print("\n=== what only 50/51 can express (30/31 has no vocabulary for these) ===")
plat = MODELS[1]
EXTRA = [
    ("approved vendor image in a FOREIGN namespace", ["VENDOR_A"], "pod", "other-team", False),
    ("approved vendor image in demo-uat",            ["VENDOR_A"], "pod", "demo-uat",   True),
    ("platform image (CoreDNS) in an app namespace", ["COREDNS"],  "pod", DEMO_NS,      True),
    ("platform image beside a signed app",           ["IMG_20","COREDNS"], "pod", DEMO_NS, True),
    ("platform image beside an UNSIGNED app",        ["IMG_10","COREDNS"], "pod", DEMO_NS, False),
]
for label, keys, shape, ns, want in EXTRA:
    got, why = plat.admitted([F[k] for k in keys], shape, ns)
    ok = got == want
    rc |= (not ok)
    print(f"  {'ok  ' if ok else 'FAIL'}  {'ADMIT' if got else 'BLOCK':6} {label:46} [{ns}]  {why}")

print("\nOFFLINE PARITY:", "OK" if rc == 0 else "MISMATCH")
sys.exit(rc)

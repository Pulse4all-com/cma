#!/usr/bin/env python3
"""The URL map change of docs/signed-out/deploy.sh, computed locally from the map as it is (standard library only).

  python3 urlmap.py plan <before.json> <host> <web backend link> <bucket backend link> <new.json> <validate.json>
  python3 urlmap.py check <validate output.json>

plan: from `gcloud compute url-maps describe --format=json`, the new map with the two route rules for the
Workspace's host, and a copy with url-map tests for `gcloud compute url-maps validate`:
  priority 1  prefix /signed-out with query gcp-iap-mode=CLEAR_LOGIN_COOKIE -> the web backend (IAP)
  priority 2  prefix /signed-out -> the backend bucket
The map's default service and every other host rule and path matcher stay exactly as they are. Without a host
rule for the host (the map's default service serves it), a path matcher cma-web with the map's default service
(which must be the web backend) and a host rule for the host are added. A path matcher with pathRules is
converted to routeRules with the same matching: an exact path to fullPathMatch, a path ending in /* to
prefixMatch (without the *), longer paths first, an exact path before a prefix of the same length (a path
rule's longest match); a path rule with its own routeAction or redirect, or a * elsewhere, stops the plan.
Then the new map, with the change taken out again, must equal the old one: any other difference stops it.
Rerunning when both rules are in place changes nothing. Exit 1 with a STOP line on anything unexpected.

check: the JSON of `gcloud compute url-maps validate --format=json`: the map must load and every test pass.
"""
import copy
import json
import sys

OUTPUT_ONLY = ("creationTimestamp", "id", "kind", "selfLink")
SIGNED_OUT = "/signed-out"
MATCHER = "cma-web"


def stop(msg):
    print(f"e. STOP: {msg}")
    sys.exit(1)


def rules(web, bucket):
    return [
        {"priority": 1, "description": "signed-out: IAP clears its cookie (README, Authentication)",
         "matchRules": [{"prefixMatch": SIGNED_OUT,
                         "queryParameterMatches": [{"name": "gcp-iap-mode", "exactMatch": "CLEAR_LOGIN_COOKIE"}]}],
         "service": web},
        {"priority": 2, "description": "signed-out: the static page outside IAP (docs/signed-out)",
         "matchRules": [{"prefixMatch": SIGNED_OUT}],
         "service": bucket},
    ]


def same_link(a, b):
    """Two resource links name the same resource (a selfLink may be full or partial)"""
    tail = lambda x: "/".join((x or "").rstrip("/").split("/")[-4:])
    return tail(a) == tail(b)


def canon(m):
    m = {k: v for k, v in m.items() if k not in OUTPUT_ONLY + ("fingerprint",)}
    return json.dumps(m, sort_keys=True)


def convert(path_rules):
    out = []
    for pr in path_rules:
        if "routeAction" in pr or "urlRedirect" in pr or "customErrorResponsePolicy" in pr:
            stop("a path rule has its own route action or redirect; convert it by hand")
        for p in pr["paths"]:
            if p.endswith("/*") and "*" not in p[:-1]:
                out.append((len(p) - 1, 1, {"prefixMatch": p[:-1]}, pr["service"]))
            elif "*" not in p:
                out.append((len(p), 0, {"fullPathMatch": p}, pr["service"]))
            else:
                stop(f"path rule {p} has a * that is not at the end after a /")
    out.sort(key=lambda x: (-x[0], x[1]))
    return [{"priority": 10 * (i + 1), "matchRules": [m], "service": s} for i, (_, _, m, s) in enumerate(out)]


def sample(path):
    return path[:-1] + "x" if path.endswith("*") else path


def plan(before_path, host, web, bucket, new_path, validate_path):
    before = json.load(open(before_path))
    new = {k: v for k, v in copy.deepcopy(before).items() if k not in OUTPUT_ONLY}
    new_rules = rules(web, bucket)
    host_rules = new.setdefault("hostRules", [])
    matchers = new.setdefault("pathMatchers", [])
    hr = next((h for h in host_rules if host in h.get("hosts", [])), None)
    added = converted = None
    if hr is None:
        if not same_link(new.get("defaultService"), web):
            stop(f"{host} has no host rule and the map's default service is not the web backend; check the map by hand")
        if any(m["name"] == MATCHER for m in matchers):
            stop(f"a path matcher {MATCHER} exists but no host rule sends {host} to it")
        pm = {"name": MATCHER, "defaultService": new["defaultService"], "routeRules": new_rules}
        matchers.append(pm)
        host_rules.append({"hosts": [host], "pathMatcher": MATCHER})
        added = MATCHER
        print(f"e. plan: {host} has no host rule (the map's default service serves it): add path matcher {MATCHER} "
              f"(default service as the map's) with the two route rules, and a host rule for {host}")
    else:
        pm = next(m for m in matchers if m["name"] == hr["pathMatcher"])
        existing = pm.get("routeRules", [])
        mine = [r for r in existing if r.get("priority") in (1, 2)]
        if len(mine) == 2 and all(json.dumps({k: r[k] for k in ("matchRules", "service")}, sort_keys=True) ==
                                  json.dumps({k: n[k] for k in ("matchRules", "service")}, sort_keys=True)
                                  for r, n in zip(sorted(mine, key=lambda r: r["priority"]), new_rules)):
            print("e. plan: both route rules are in place; nothing to change")
            json.dump(new, open(new_path, "w"), indent=2)
            json.dump(new, open(validate_path, "w"), indent=2)
            return
        if mine:
            stop(f"path matcher {pm['name']} already has a route rule with priority 1 or 2; check the map by hand")
        if pm.get("pathRules"):
            converted = copy.deepcopy(pm["pathRules"])
            existing = convert(pm.pop("pathRules"))
            print(f"e. plan: path matcher {pm['name']} uses pathRules; converted to {len(existing)} route rules, same matching")
        pm["routeRules"] = new_rules + existing
        print(f"e. plan: the two route rules added to path matcher {pm['name']} (host rule {', '.join(hr['hosts'])})")

    # The change taken out again must give the map as it was: nothing else may differ
    back = copy.deepcopy(new)
    if added:
        back["pathMatchers"] = [m for m in back["pathMatchers"] if m["name"] != added]
        back["hostRules"] = [h for h in back["hostRules"] if h.get("pathMatcher") != added]
        for key in ("pathMatchers", "hostRules"):
            if not back[key] and key not in before:
                del back[key]
    else:
        bpm = next(m for m in back["pathMatchers"] if m["name"] == hr["pathMatcher"])
        bpm["routeRules"] = [r for r in bpm["routeRules"] if r.get("priority") not in (1, 2)]
        if converted is not None:
            del bpm["routeRules"]
            bpm["pathRules"] = converted
        elif not bpm["routeRules"] and "routeRules" not in next(m for m in before["pathMatchers"] if m["name"] == hr["pathMatcher"]):
            del bpm["routeRules"]
    if canon(back) != canon(before):
        stop("the new map differs from the export in more than the two route rules; nothing is imported")
    print("e. check: apart from the two route rules (and a converted path matcher's same matching), the map is as exported")

    # Tests for validate: what the map answered before, for every host's start page, a path no rule names
    # and every path rule; the new route; the map's default. A matcher with route rules of its own is left to
    # its own tests (its matching is not computed here)
    def old_service(h, path):
        rule = next((x for x in before.get("hostRules", []) if h in x.get("hosts", [])), None)
        if rule is None:
            return before.get("defaultService")
        m = next(x for x in before["pathMatchers"] if x["name"] == rule["pathMatcher"])
        if m.get("routeRules"):
            return None
        best = None
        for pr in m.get("pathRules", []):
            for p in pr["paths"]:
                hit = path == p if "*" not in p else path.startswith(p[:-1])
                size = (len(p) - (1 if "*" in p else 0), "*" not in p)
                if hit and (best is None or size > best[0]):
                    best = (size, pr["service"])
        return best[1] if best else m["defaultService"]

    tests = list(new.get("tests", []))
    hosts = {hh for x in new.get("hostRules", []) for hh in x.get("hosts", []) if "*" not in hh} | {host}
    for hh in sorted(hosts):
        rule = next((x for x in before.get("hostRules", []) if hh in x.get("hosts", [])), None)
        m = next((x for x in before.get("pathMatchers", []) if rule and x["name"] == rule["pathMatcher"]), None)
        paths = ["/", "/cma-urlmap-test"] + [sample(p) for pr in (m or {}).get("pathRules", []) for p in pr["paths"]]
        for path in paths:
            if hh == host and path.startswith(SIGNED_OUT):
                continue
            svc = old_service(hh, path)
            if svc:
                tests.append({"host": hh, "path": path, "service": svc})
    tests.append({"host": host, "path": SIGNED_OUT, "service": bucket})
    tests.append({"host": "cma-urlmap-test.invalid", "path": "/", "service": new["defaultService"]})
    json.dump(new, open(new_path, "w"), indent=2)
    json.dump({**new, "tests": tests}, open(validate_path, "w"), indent=2)
    print(f"e. plan written: {new_path} (imported), {validate_path} (with {len(tests)} tests, validated only)")


def check(path):
    out = json.load(open(path))
    res = out.get("result", out)
    if not res.get("loadSucceeded"):
        stop(f"the map does not load: {res.get('loadErrors')}")
    if res.get("testPassed") is False:
        stop(f"a url-map test fails: {res.get('testFailures')}")
    print("e. validate: the map loads and every test passes")


if __name__ == "__main__":
    if len(sys.argv) == 8 and sys.argv[1] == "plan":
        plan(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        check(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)

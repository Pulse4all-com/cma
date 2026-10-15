#!/usr/bin/env python3
"""The fake gcloud's URL map: the live map is the JSON file $FAKE_URLMAP (standard library only).

  urlmap-state.py describe <map.json> fingerprint   what `describe --format='value(fingerprint)'` prints
  urlmap-state.py export <map.json> <destination>   what `url-maps export` writes: the map's top-level fields,
                                                    one per line (flow values, valid YAML), fingerprint included,
                                                    the output-only fields left out, as gcloud's export schema does
  urlmap-state.py import <map.json> <source>        a missing or stale fingerprint is refused with 412, as gcloud
                                                    warns later versions will (gcloud 570.0.0 swaps in the live
                                                    one); otherwise the map is replaced and gets a new fingerprint
  urlmap-state.py change <map.json>                 someone else changes the map: a description, a new fingerprint
"""
import base64
import hashlib
import json
import sys

OUTPUT_ONLY = ("creationTimestamp", "id", "kind", "selfLink")


def fingerprinted(m):
    body = {k: v for k, v in m.items() if k != "fingerprint"}
    digest = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).digest()[:8]
    return {**body, "fingerprint": base64.urlsafe_b64encode(digest).decode()}


def load_source(path):
    text = open(path).read()
    if text.lstrip().startswith("{"):
        return json.loads(text)
    out = {}
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        key, _, value = line.partition(": ")
        out[key] = value[1:-1] if value.startswith("'") and value.endswith("'") else json.loads(value)
    return out


def main(cmd, path, arg=None):
    live = json.load(open(path))
    if cmd == "describe":
        print(live["fingerprint"])
    elif cmd == "export":
        with open(arg, "w") as f:
            for k in sorted(live):
                if k not in OUTPUT_ONLY:
                    f.write(f"{k}: {json.dumps(live[k])}\n")
    elif cmd == "import":
        src = load_source(arg)
        if not src.get("fingerprint") or src["fingerprint"] != live["fingerprint"]:
            print("ERROR: (gcloud.compute.url-maps.import) HTTPError 412: Invalid fingerprint.", file=sys.stderr)
            sys.exit(1)
        new = {**{k: live[k] for k in OUTPUT_ONLY if k in live}, **{k: v for k, v in src.items() if k != "fingerprint"}}
        json.dump(fingerprinted(new), open(path, "w"))
        print("Updating URL map...\n...done.", file=sys.stderr)
    elif cmd == "change":
        json.dump(fingerprinted({**live, "description": "changed by someone else"}), open(path, "w"))


if __name__ == "__main__":
    main(*sys.argv[1:])

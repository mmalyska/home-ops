"""Turn CustomResourceDefinitions into kubeconform JSON schemas.

    yq ea -o json '[select(.kind == "CustomResourceDefinition")]' renders/*.yaml \
      | python3 -I crd2schema.py <outdir>

Reads a JSON array of CRDs on stdin and writes <outdir>/<group>/<kind lowercase>_<version>.json for every
version with an openAPIV3Schema, the layout kubeconform's
"{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" schema location expects.

The schemas are strict like kubeconform's own openapi2jsonschema: an object with `properties` and no
`additionalProperties` or `x-kubernetes-preserve-unknown-fields` rejects unknown fields. apiVersion, kind and
metadata are added to the root, since CRD schemas may leave them out.

Standard library only.
"""

import copy
import json
import os
import sys


def strict(node):
    if isinstance(node, dict):
        if (
            node.get("type") == "object"
            and "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for value in node.values():
            strict(value)
    elif isinstance(node, list):
        for value in node:
            strict(value)
    return node


def main():
    if len(sys.argv) != 2:
        print("usage: crd2schema.py <outdir> < crds.json", file=sys.stderr)
        return 2
    out = sys.argv[1]
    written = 0
    for crd in json.load(sys.stdin) or []:
        spec = crd.get("spec") or {}
        group = spec.get("group")
        kind = (spec.get("names") or {}).get("kind", "").lower()
        if not group or not kind:
            continue
        for version in spec.get("versions") or []:
            schema = (version.get("schema") or {}).get("openAPIV3Schema")
            if not schema:
                continue
            schema = strict(copy.deepcopy(schema))
            props = schema.setdefault("properties", {})
            props.setdefault("apiVersion", {"type": "string"})
            props.setdefault("kind", {"type": "string"})
            props.setdefault("metadata", {"type": "object"})
            os.makedirs(os.path.join(out, group), exist_ok=True)
            path = os.path.join(out, group, f"{kind}_{version['name']}.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(schema, f)
            written += 1
    print(f"crd2schema: {written} schemas written", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

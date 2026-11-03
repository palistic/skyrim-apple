#!/usr/bin/env python3
"""Write only exact input hashes into a private app resource, never host paths."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"macos"))
from inputs import verify_generated

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("generated",type=Path)
parser.add_argument("output",type=Path)
args=parser.parse_args()
receipt=verify_generated(args.generated)
resource={"schema":1,"generated_manifest_sha256":hashlib.sha256((args.generated/"input-manifest.json").read_bytes()).hexdigest(),
          "modules":{name:value["sha256"] for name,value in receipt["modules"].items()},
          "essential_data":{name:value["sha256"] for name,value in receipt["essential_data"].items()}}
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(resource,indent=2)+"\n")

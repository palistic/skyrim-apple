#!/usr/bin/env python3
"""Configure and build the native iPad Simulator port with concise durable logs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
SIM=ROOT/"simulator"
BUILD=SIM/"build/native"


def run(command,name):
    log=SIM/"build"/(name+".log")
    log.parent.mkdir(parents=True,exist_ok=True)
    with log.open("w") as output:
        result=subprocess.run(command,cwd=ROOT,stdout=output,stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-6000:])
        raise SystemExit(result.returncode)
    print(name,"passed; log:",log)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game",action="store_true",help="Requires verified private original Windows gen/")
    parser.add_argument("--audio",action="store_true",help="Enable the private Simulator native xWMA backend")
    parser.add_argument("--jobs",type=int,choices=(1,2),default=2,help="Maximum compiler jobs, shared with other port work")
    parser.add_argument("--fresh",action="store_true",
                        help="Discard the cached CMake configuration first (needed after an Xcode/Simulator SDK update)")
    args=parser.parse_args()
    receipt_path=SIM/"build/moltenvk-receipt.json"
    if not receipt_path.exists(): parser.error("Run simulator/bootstrap.py first")
    dependency=json.loads(receipt_path.read_text())
    library=Path(dependency["library"])
    if dependency.get("platform")!="ios-simulator" or dependency.get("architecture")!="arm64" or hashlib.sha256(library.read_bytes()).hexdigest()!=dependency["library_sha256"]:
        parser.error("The private MoltenVK slice changed or targets the wrong Apple platform")
    run([sys.executable,str(SIM/"generate_fixture.py"),"--output",str(BUILD/"fixture")],"fixture-generation")
    run(["cmake",*(["--fresh"] if args.fresh else []),"-S",str(SIM),"-B",str(BUILD),"-G","Ninja",
         "-DCMAKE_TOOLCHAIN_FILE="+str(SIM/"toolchain.cmake"),"-DCMAKE_BUILD_TYPE=Release",
         "-DSKYRIM_MOLTENVK_LIBRARY="+str(library),"-DSKYRIM_SIM_BUILD_GAME="+("ON" if args.game else "OFF"),
         "-DSKYRIM_FFMPEG_AUDIO="+("ON" if args.audio else "OFF")],"app-configure")
    source_files={Path(item["file"]).resolve() for item in json.loads((BUILD/"compile_commands.json").read_text())}
    source_files.update(p for p in SIM.iterdir() if p.is_file())
    source_files.update((ROOT/"runtime").glob("*.h"))
    source_files.update((ROOT/"macos/audio").glob("*.h"))
    source_hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source_files)}
    run(["cmake","--build",str(BUILD),"--parallel",str(args.jobs)],"app-build")
    if any(hashlib.sha256(Path(p).read_bytes()).hexdigest()!=digest for p,digest in source_hashes.items()):
        raise SystemExit("Build source changed during compilation; inspect and rebuild before accepting the app")
    names=["SkyrimRuntimeProbe.app/SkyrimRuntimeProbe","SkyrimRuntimeProbe.app/Frameworks/libSDL2-2.0.0.dylib",
           "SkyrimRuntimeProbe.app/Frameworks/libdxvk_d3d9.dylib"]
    if args.game: names += ["SkyrimJitless.app/SkyrimJitless","SkyrimJitless.app/Frameworks/libSDL2-2.0.0.dylib",
                            "SkyrimJitless.app/Frameworks/libdxvk_d3d9.dylib"]
    artifacts={name:{"sha256":hashlib.sha256((BUILD/name).read_bytes()).hexdigest(),
                     "platform":subprocess.check_output(["xcrun","vtool","-show-build",str(BUILD/name)],text=True)} for name in names}
    if any("IOSSIMULATOR" not in value["platform"] for value in artifacts.values()):
        raise SystemExit("A build artifact is not an actual iOS Simulator binary")
    receipt={"schema":1,"game_built":args.game,
        "audio_enabled":args.audio,"moltenvk":dependency,"sources":source_hashes,"artifacts":artifacts}
    if args.game:
        # Bind the game app to the exact verified gen/ it compiled (run_game.py checks this).
        receipt["generated_manifest_sha256"]=hashlib.sha256((ROOT/"gen/input-manifest.json").read_bytes()).hexdigest()
        receipt["game_input_resource_sha256"]=hashlib.sha256((BUILD/"SkyrimJitless.app/game-input-manifest.json").read_bytes()).hexdigest()
    (SIM/"build/app-build-receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__=="__main__": main()

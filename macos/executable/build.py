#!/usr/bin/env python3
"""Retarget pinned, unmodified Steamless core sources for a private Mac host tool."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from xml.sax.saxutils import escape

from common import COMMIT, ROOT, SHARP_SHA256, SOURCE, VARIANTS, WORK, digest, file_record, write_json


def run(args: list[str], **kwargs) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, **kwargs)


def project(path: Path, name: str, sources: list[Path], references: list[Path], sharp: Path | None = None,
            executable: bool = False) -> None:
    def item(kind: str, value: Path) -> str:
        return f'<{kind} Include="{escape(str(value), {chr(34): "&quot;"})}" />'
    items = [item("Compile", p) for p in sources] + [item("ProjectReference", p) for p in references]
    if sharp:
        items.append(f'<Reference Include="SharpDisasm"><HintPath>{escape(str(sharp))}</HintPath></Reference>')
    path.write_text(f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework><PlatformTarget>AnyCPU</PlatformTarget>
    <AssemblyName>{name}</AssemblyName><OutputType>{"Exe" if executable else "Library"}</OutputType>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems><GenerateAssemblyInfo>false</GenerateAssemblyInfo>
    <UseAppHost>false</UseAppHost><Nullable>disable</Nullable><ImplicitUsings>disable</ImplicitUsings>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks><Deterministic>true</Deterministic>
    <BuildInParallel>false</BuildInParallel><UseSharedCompilation>false</UseSharedCompilation>
  </PropertyGroup><ItemGroup>{''.join(items)}</ItemGroup>
</Project>\n''')


def build(source: Path, dotnet: Path) -> Path:
    source = source.resolve()
    dotnet = dotnet.resolve()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("This private host build expects native ARM64 macOS")
    if run(["git", "-C", str(source), "rev-parse", "HEAD"]).strip() != COMMIT:
        raise ValueError("Steamless source is not the pinned official revision")
    if run(["git", "-C", str(source), "status", "--porcelain"]).strip():
        raise ValueError("Preserve and review modified Steamless source before building")
    tracked = run(["git", "-C", str(source), "ls-files", "-z"]).split("\0")
    source_records = [file_record(source / name) for name in tracked if name]
    for variant in ("20", "21"):
        if digest(source / f"Steamless.Unpacker.Variant{variant}.x86/SharpDisasm.dll") != SHARP_SHA256:
            raise ValueError("Unexpected bundled SharpDisasm binary")
    WORK.mkdir(parents=True, exist_ok=True)
    build_dir = Path(tempfile.mkdtemp(prefix="host-", dir=WORK))
    projects = build_dir / "projects"
    projects.mkdir()
    (build_dir / "NuGet.Config").write_text('<configuration><packageSources><clear /></packageSources></configuration>\n')
    (build_dir / "global.json").write_text(json.dumps({"sdk": {"version": "10.0.402", "rollForward": "disable"}}))
    env = os.environ | {"DOTNET_CLI_HOME": str(build_dir / "cli-home"), "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
                        "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1", "DOTNET_NOLOGO": "1",
                        "NUGET_PACKAGES": str(build_dir / "packages")}
    sdk_info = run([str(dotnet), "--info"], cwd=build_dir, env=env)
    if "Architecture: arm64" not in sdk_info and "Architecture:   arm64" not in sdk_info:
        # Spacing varies across SDK patches; parse the host line explicitly.
        if not any(line.strip().startswith("Architecture:") and line.split(":", 1)[1].strip() == "arm64" for line in sdk_info.splitlines()):
            raise ValueError("dotnet host is not ARM64")
    (build_dir / "dotnet-info.txt").write_text(sdk_info)
    api_dir = projects / "api"
    api_dir.mkdir()
    api = api_dir / "api.csproj"
    excluded = {"Model/ViewModelBase.cs", "Model/NavigatedEventArgs.cs"}
    api_sources = [p for p in sorted((source / "Steamless.API").rglob("*.cs"))
                   if p.relative_to(source / "Steamless.API").as_posix() not in excluded]
    project(api, "Steamless.API", api_sources, [])
    cli_dir = projects / "cli"
    cli_dir.mkdir()
    cli_project = cli_dir / "cli.csproj"
    project(cli_project, "Steamless.CLI", sorted((source / "Steamless.CLI").rglob("*.cs")), [api], executable=True)
    targets = [(cli_project, "cli")]
    probe_dir = projects / "probe"
    probe_dir.mkdir()
    probe_project = probe_dir / "probe.csproj"
    probe_source = Path(__file__).parent / "HostProbe.cs"
    project(probe_project, "HostProbe", [probe_source], [api],
            source / "Steamless.Unpacker.Variant20.x86/SharpDisasm.dll", executable=True)
    targets.append((probe_project, "probe"))
    for variant in VARIANTS:
        name = f"Steamless.Unpacker.Variant{variant}.x86"
        dest = projects / f"variant{variant}"
        dest.mkdir()
        csproj = dest / "plugin.csproj"
        project(csproj, name, sorted((source / name).rglob("*.cs")), [api],
                source / name / "SharpDisasm.dll" if variant in ("20", "21") else None)
        targets.append((csproj, f"variant{variant}"))
    # SDK projects are isolated under ignored outputs; original sources remain pristine.
    for csproj, label in targets:
        command = [str(dotnet), "build", str(csproj), "-c", "Release", "-m:1", "--nologo",
                   "-p:BuildInParallel=false", "-p:UseSharedCompilation=false", "--configfile", str(build_dir / "NuGet.Config")]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=build_dir, env=env)
        (build_dir / f"build-{label}.log").write_text(result.stdout)
        if result.returncode:
            raise ValueError(f"Build failed: {build_dir / ('build-' + label + '.log')}")
    output = build_dir / "tool"
    output.mkdir()
    plugins = output / "Plugins"
    plugins.mkdir()
    for p in (cli_dir / "bin/Release/net10.0").iterdir():
        if p.suffix in (".dll", ".json"):
            shutil.copyfile(p, output / p.name)
    for p in (probe_dir / "bin/Release/net10.0").iterdir():
        if p.name.startswith("HostProbe.") and p.suffix in (".dll", ".json"):
            shutil.copyfile(p, output / p.name)
    # Probe resolves this explicitly; original CLI resolves the same managed DLL in Plugins/.
    shutil.copyfile(source / "Steamless.Unpacker.Variant20.x86/SharpDisasm.dll", output / "SharpDisasm.dll")
    for variant in VARIANTS:
        name = f"Steamless.Unpacker.Variant{variant}.x86.dll"
        shutil.copyfile(projects / f"variant{variant}/bin/Release/net10.0" / name, plugins / name)
    shutil.copyfile(source / "Steamless.Unpacker.Variant20.x86/SharpDisasm.dll", plugins / "SharpDisasm.dll")
    inputs = source_records + [file_record(p) for p in sorted(Path(__file__).parent.glob("*.py"))]
    inputs.append(file_record(probe_source))
    inputs += [file_record(p) for p in sorted(projects.rglob("*.csproj"))]
    inputs += [file_record(build_dir / "NuGet.Config"), file_record(build_dir / "global.json")]
    for record in source_records:
        if digest(Path(record["path"])) != record["sha256"]:
            raise ValueError("Source changed during build")
    receipt = {"kind": "steamless-headless-build-v1", "source_commit": COMMIT,
               "target_framework": "net10.0", "platform_target": "AnyCPU", "host_architecture": "arm64",
               "excluded_api_types": sorted(excluded), "checksum_option_supported": False,
               "source_license": "CC-BY-NC-ND-4.0; private adaptation only; do not redistribute",
               "sharpdisasm_sha256": SHARP_SHA256, "sharpdisasm_clr_flags": "0x1 (ILONLY)",
               "dotnet": file_record(dotnet), "sdk_info": sdk_info, "cli": str(output / "Steamless.CLI.dll"),
               "inputs": inputs, "outputs": [file_record(p) for p in sorted(output.rglob("*")) if p.is_file()]}
    path = build_dir / "receipt.json"
    write_json(path, receipt)
    # Only this small local pointer is replaced after a successful complete build.
    pointer = WORK / "CURRENT.json"
    temporary = build_dir / "current.json"
    write_json(temporary, {"kind": "steamless-current-v1", "receipt": file_record(path)})
    os.replace(temporary, pointer)
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--dotnet", type=Path, default=Path(shutil.which("dotnet") or "/opt/homebrew/bin/dotnet"))
    arguments = parser.parse_args()
    try:
        print(build(arguments.source, arguments.dotnet))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")

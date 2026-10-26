#!/usr/bin/env python3
"""Embed and relocate a macOS dylib dependency closure before code signing."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def load_commands(binary):
    dependencies, rpaths = [], []
    for block in re.split(r"Load command \d+\n", run("otool", "-l", binary)):
        command = re.search(r"^\s*cmd (LC_\w+)$", block, re.M)
        if not command:
            continue
        kind = command.group(1)
        if kind in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}:
            dependencies.append(re.search(r"^\s*name (.+) \(offset \d+\)$", block, re.M).group(1))
        elif kind == "LC_RPATH":
            rpaths.append(re.search(r"^\s*path (.+) \(offset \d+\)$", block, re.M).group(1))
    return list(dict.fromkeys(dependencies)), list(dict.fromkeys(rpaths))


def system_library(name):
    return name.startswith(("/System/Library/", "/usr/lib/")) or bool(
        re.fullmatch(r"@rpath/libswift\w+\.dylib", name))


def expand(name, owner, executable):
    return name.replace("@loader_path", str(owner.parent)).replace(
        "@executable_path", str(executable.parent))


def resolve(name, owner, executable, rpaths, search_paths):
    expanded = expand(name, owner, executable)
    candidates = ([Path(p) / name[len("@rpath/"):] for p in rpaths]
                  if name.startswith("@rpath/") else [Path(expanded)])
    candidates += [Path(p) / Path(name).name for p in search_paths]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise ValueError(f"Cannot resolve {name} required by {owner}; add its directory with --search-path")


def executable_in(app):
    import plistlib
    with (app / "Contents/Info.plist").open("rb") as stream:
        name = plistlib.load(stream)["CFBundleExecutable"]
    if Path(name).name != name:
        raise ValueError("Invalid CFBundleExecutable")
    return app / "Contents/MacOS" / name


def verify(app):
    executable = executable_in(app)
    frameworks = app / "Contents/Frameworks"
    manifest = app / "Contents/Resources/vulkan-runtime.json"
    data = json.loads(manifest.read_text())
    if data.get("version") != 1 or data.get("backend") != "MoltenVK":
        raise ValueError("Unrecognized bundled Vulkan runtime manifest")
    names = data["libraries"]
    if "libMoltenVK.dylib" not in names:
        raise ValueError("Bundled MoltenVK is missing")
    for name, metadata in names.items():
        if Path(name).name != name or not (frameworks / name).is_file():
            raise ValueError(f"Missing/invalid bundled library: {name}")
        for license_file in metadata["licenses"]:
            path = app / "Contents/Resources/Licenses/Vulkan" / license_file
            if not path.resolve().is_relative_to((app / "Contents/Resources/Licenses/Vulkan").resolve()):
                raise ValueError("Invalid license path")
            if not path.is_file() or not path.stat().st_size:
                raise ValueError(f"Missing runtime license: {license_file}")
        if not metadata["licenses"]:
            raise ValueError(f"No license recorded for {name}")
    arches = set(run("lipo", "-archs", executable).split())
    for binary in [executable] + [frameworks / name for name in names]:
        if not arches.issubset(set(run("lipo", "-archs", binary).split())):
            raise ValueError(f"Architecture mismatch: {binary}")
        dependencies, _ = load_commands(binary)
        for dependency in dependencies:
            if system_library(dependency):
                continue
            expected = ("@executable_path/../Frameworks/" if binary == executable else "@loader_path/")
            if not dependency.startswith(expected) or dependency[len(expected):] not in names:
                raise ValueError(f"Non-bundled dependency in {binary}: {dependency}")
    print(f"Verified bundled MoltenVK and {len(names)} runtime libraries")


def bundle(app, moltenvk, license_manifest, search_paths):
    executable = executable_in(app)
    licenses = json.loads(license_manifest.read_text())
    frameworks = app / "Contents/Frameworks"
    license_dir = app / "Contents/Resources/Licenses/Vulkan"
    # Plan everything before modifying the staged app. Framework dependencies
    # require a dedicated framework packager; this helper accepts dylibs only.
    sources, destinations, edges, source_rpaths = {}, {}, {}, {}
    required_arches = set(run("lipo", "-archs", executable).split())

    def visit(source, inherited=(), name=None):
        source = source.resolve()
        if source in destinations:
            return destinations[source]
        target = name or source.name
        if not target.endswith(".dylib"):
            raise ValueError(f"Only dylib dependencies are supported: {source}")
        if target in sources and sources[target] != source:
            raise ValueError(f"Different runtime libraries have the same name: {target}")
        if not required_arches.issubset(set(run("lipo", "-archs", source).split())):
            raise ValueError(f"{source} does not contain app architectures: {sorted(required_arches)}")
        if target not in licenses or not licenses[target]:
            raise ValueError(f"Add license/notice files for {target} to {license_manifest}")
        for license_name in licenses[target]:
            license_path = (license_manifest.parent / license_name).resolve()
            if not license_path.is_file() or not license_path.stat().st_size:
                raise ValueError(f"Missing/empty license file: {license_path}")
        sources[target], destinations[source] = source, target
        dependencies, rpaths = load_commands(source)
        source_rpaths[source] = rpaths
        lookup = [expand(p, source, executable) for p in rpaths] + list(inherited)
        edges[source] = {}
        for dependency in dependencies:
            if not system_library(dependency):
                resolved = resolve(dependency, source, executable, lookup, search_paths)
                edges[source][dependency] = visit(resolved, lookup)
        return target

    exe_dependencies, exe_rpaths = load_commands(executable)
    inherited = [expand(p, executable, executable) for p in exe_rpaths]
    visit(moltenvk, inherited, "libMoltenVK.dylib")
    edges[executable.resolve()] = {}
    for dependency in exe_dependencies:
        if not system_library(dependency):
            resolved = resolve(dependency, executable, executable, inherited, search_paths)
            edges[executable.resolve()][dependency] = visit(resolved, inherited)
    if not any(name.startswith("libplacebo.") or name == "libplacebo.dylib" for name in sources):
        raise ValueError("Enabled executable must dynamically link libplacebo; build with MOONLIGHT_LIBPLACEBO=1")
    frameworks.mkdir(parents=True, exist_ok=True)
    license_dir.mkdir(parents=True, exist_ok=True)
    manifest = {"version": 1, "backend": "MoltenVK", "libraries": {}}
    for name, source in sources.items():
        destination = frameworks / name
        shutil.copy2(source, destination)
        destination.chmod(destination.stat().st_mode | 0o200)
        run("install_name_tool", "-id", "@rpath/" + name, destination)
        copied_licenses = []
        for index, license_name in enumerate(licenses[name]):
            filename = f"{name}/{index}-{Path(license_name).name}"
            target = license_dir / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2((license_manifest.parent / license_name).resolve(), target)
            copied_licenses.append(filename)
        manifest["libraries"][name] = {"licenses": copied_licenses}
    for source, dependencies in edges.items():
        is_exe = source == executable.resolve()
        destination = executable if is_exe else frameworks / destinations[source]
        prefix = "@executable_path/../Frameworks/" if is_exe else "@loader_path/"
        for old, name in dependencies.items():
            run("install_name_tool", "-change", old, prefix + name, destination)
        for rpath in exe_rpaths if is_exe else source_rpaths[source]:
            if not rpath.startswith(("@", "/usr/lib/", "/System/Library/")):
                run("install_name_tool", "-delete_rpath", rpath, destination)
    (app / "Contents/Resources/vulkan-runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verify(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--moltenvk", type=Path)
    parser.add_argument("--licenses", type=Path)
    parser.add_argument("--search-path", action="append", default=[])
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.app.resolve())
        else:
            if not args.moltenvk or not args.licenses:
                parser.error("--moltenvk and --licenses are required when bundling")
            bundle(args.app.resolve(), args.moltenvk.resolve(), args.licenses.resolve(), args.search_path)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Vulkan runtime packaging failed: {error}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compile, bundle, sign, and run the real GPU test using development dependencies.

Requires the same MOONLIGHT_MOLTENVK_DYLIB / MOONLIGHT_RUNTIME_LICENSES variables
as package_app.sh and a Vulkan-enabled libplacebo.pc on PKG_CONFIG_PATH.
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("runtime_bundle", ROOT / "Scripts/bundle_vulkan_runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def main():
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "libplacebo"], text=True))
    moltenvk = Path(os.environ["MOONLIGHT_MOLTENVK_DYLIB"])
    licenses = Path(os.environ["MOONLIGHT_RUNTIME_LICENSES"])
    search_paths = [os.environ["MOONLIGHT_RUNTIME_LIBRARY_DIR"]] if os.environ.get("MOONLIGHT_RUNTIME_LIBRARY_DIR") else []
    with tempfile.TemporaryDirectory(prefix="moonlight-vulkan-gpu-") as directory:
        app = Path(directory) / "MoonlightVulkanSmoke.app"
        executable = app / "Contents/MacOS/MoonlightMac"
        executable.parent.mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "MoonlightMac", "CFBundleIdentifier": "com.eckobrew.moonlight.vulkan-smoke",
            "CFBundlePackageType": "APPL"}))
        subprocess.run(["clang", "-fobjc-arc", "-DMOONLIGHT_LIBPLACEBO=1", "-DMLPLACEBO_TESTING=1",
                        "-I", str(ROOT / "Sources/CPlaceboBridge/include"),
                        str(ROOT / "Sources/CPlaceboBridge/CPlaceboBridge.m"),
                        str(ROOT / "Tests/Packaging/vulkan_smoke.m"), *flags,
                        "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "CoreVideo", "-framework", "Metal",
                        "-Wl,-headerpad_max_install_names", "-o", str(executable)], check=True)
        runtime.bundle(app, moltenvk, licenses, search_paths)
        for library in (app / "Contents/Frameworks").glob("*.dylib"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        environment = dict(os.environ)
        for name in list(environment):
            if name.startswith(("DYLD_", "VK_", "MVK_")):
                del environment[name]
        subprocess.run([str(executable)], env=environment, check=True, timeout=130)


if __name__ == "__main__":
    main()

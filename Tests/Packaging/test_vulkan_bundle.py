"""Real Mach-O fixtures verify relocation without requiring Vulkan hardware."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/bundle_vulkan_runtime.py"
spec = importlib.util.spec_from_file_location("runtime_bundle", SCRIPT)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class VulkanBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="moonlight-vulkan-package-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # Spaces in paths exercise otool parsing and subprocess argument handling.
        self.deps = self.root / "external libraries"
        self.deps.mkdir()
        self.app = self.root / "Moonlight.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir()
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "MoonlightMac", "CFBundleIdentifier": "test.moonlight.bundle",
            "CFBundlePackageType": "APPL"}))
        self.compile_library("libfixture.dylib", "int fixture(void) { return 21; }")
        self.compile_library("libplacebo.360.dylib", "int fixture(void); int placebo(void) { return fixture(); }",
                             self.deps / "libfixture.dylib")
        self.compile_library("libMoltenVK.dylib", "int molten(void) { return 21; }")
        source = self.root / "main.m"
        source.write_text('''#import <Foundation/Foundation.h>
#include <dlfcn.h>
int placebo(void);
int main(void) { @autoreleasepool {
    NSString *path = [[NSBundle mainBundle].privateFrameworksPath
        stringByAppendingPathComponent:@"libMoltenVK.dylib"];
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) return 2;
    int (*molten)(void) = dlsym(handle, "molten");
    int result = molten ? placebo() + molten() : 0;
    dlclose(handle);
    return result == 42 ? 0 : 3;
} }
''')
        subprocess.run(["clang", "-fobjc-arc", str(source), "-framework", "Foundation",
                        str(self.deps / "libplacebo.360.dylib"), "-Wl,-headerpad_max_install_names",
                        "-o", str(self.app / "Contents/MacOS/MoonlightMac")], check=True)
        notice = self.root / "LICENSE.txt"
        notice.write_text("Test fixture license\n")
        self.manifest = self.root / "licenses.json"
        self.manifest.write_text(json.dumps({name: [str(notice)] for name in
            ["libfixture.dylib", "libplacebo.360.dylib", "libMoltenVK.dylib"]}))

    def compile_library(self, name, code, *dependencies):
        source = self.root / (name + ".c")
        source.write_text(code)
        library = self.deps / name
        subprocess.run(["clang", "-dynamiclib", str(source), *map(str, dependencies),
                        "-Wl,-headerpad_max_install_names", "-install_name", str(library),
                        "-o", str(library)], check=True)

    def bundle(self):
        runtime.bundle(self.app, self.deps / "libMoltenVK.dylib", self.manifest, [])

    def test_relocated_bundle_runs_without_original_libraries(self):
        self.bundle()
        self.assertEqual(len(json.loads((self.app / "Contents/Resources/vulkan-runtime.json").read_text())["libraries"]), 3)
        for library in (self.app / "Contents/Frameworks").glob("*.dylib"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True)
        shutil.rmtree(self.deps)
        moved = self.root / "relocated folder/Moonlight.app"
        moved.parent.mkdir()
        shutil.move(self.app, moved)
        runtime.verify(moved)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(moved)], check=True)
        subprocess.run([str(moved / "Contents/MacOS/MoonlightMac")], check=True,
                       env={"PATH": "/usr/bin:/bin"})

    def test_missing_transitive_license_rejected_before_copy(self):
        licenses = json.loads(self.manifest.read_text())
        del licenses["libfixture.dylib"]
        self.manifest.write_text(json.dumps(licenses))
        with self.assertRaisesRegex(ValueError, "license/notice files for libfixture"):
            self.bundle()
        self.assertFalse((self.app / "Contents/Frameworks").exists())

    def test_resolves_rpath_and_loader_path_dependencies(self):
        executable = self.app / "Contents/MacOS/MoonlightMac"
        library = self.deps / "libplacebo.360.dylib"
        subprocess.run(["install_name_tool", "-change", str(library), "@rpath/libplacebo.360.dylib",
                        "-add_rpath", str(self.deps), str(executable)], check=True)
        subprocess.run(["install_name_tool", "-change", str(self.deps / "libfixture.dylib"),
                        "@loader_path/libfixture.dylib", str(library)], check=True)
        self.bundle()
        _, rpaths = runtime.load_commands(executable)
        self.assertNotIn(str(self.deps), rpaths)
        runtime.verify(self.app)

    def test_verify_rejects_external_dependency_and_missing_license(self):
        self.bundle()
        executable = self.app / "Contents/MacOS/MoonlightMac"
        subprocess.run(["install_name_tool", "-change",
                        "@executable_path/../Frameworks/libplacebo.360.dylib",
                        str(self.deps / "libplacebo.360.dylib"), str(executable)], check=True)
        with self.assertRaisesRegex(ValueError, "Non-bundled dependency"):
            runtime.verify(self.app)
        subprocess.run(["install_name_tool", "-change", str(self.deps / "libplacebo.360.dylib"),
                        "@executable_path/../Frameworks/libplacebo.360.dylib", str(executable)], check=True)
        next((self.app / "Contents/Resources/Licenses/Vulkan").rglob("*.txt")).unlink()
        with self.assertRaisesRegex(ValueError, "Missing runtime license"):
            runtime.verify(self.app)


if __name__ == "__main__":
    unittest.main()

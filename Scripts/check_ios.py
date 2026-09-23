#!/usr/bin/env python3
"""Compile/link device sources directly. Run swift test first to resolve llama.cpp.

This checks compilation, not Xcode packaging, signing, or physical-device behavior.
"""
import argparse
import os
import plistlib
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", action="store_true", help="Compile/link for the arm64 iOS Simulator")
args = parser.parse_args()
sdk_name = "iPhoneSimulator" if args.simulator else "iPhoneOS"
target = "arm64-apple-ios17.0-simulator" if args.simulator else "arm64-apple-ios17.0"
developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
sdk = Path(developer) / f"Platforms/{sdk_name}.platform/Developer/SDKs/{sdk_name}.sdk"
out = root / ".build/ios-check" / sdk_name
out.mkdir(parents=True, exist_ok=True)
artifact = next((root / ".build/artifacts").glob("*/llama-cpp/llama.xcframework"), None)
if artifact is None:
    raise SystemExit("Run swift test first to download the pinned llama.cpp binary.")
with (artifact / "Info.plist").open("rb") as file:
    libraries = plistlib.load(file)["AvailableLibraries"]
variant = "simulator" if args.simulator else None
library = next((lib for lib in libraries if lib["SupportedPlatform"] == "ios"
                and lib.get("SupportedPlatformVariant") == variant
                and "arm64" in lib["SupportedArchitectures"]), None)
if library is None:
    raise SystemExit(f"The resolved llama.cpp binary is missing the {sdk_name} arm64 library.")
framework = artifact / library["LibraryIdentifier"]
common = ["xcrun", "--sdk", sdk_name.lower(), "swiftc", "-parse-as-library", "-swift-version", "5", "-target", target,
          "-sdk", str(sdk), "-module-cache-path", str(out / "device-cache"), "-I", str(out), "-F", str(framework)]
for module in ["NewtonCore", "NewtonLocal"]:
    sources = sorted((root / "Sources" / module).glob("*.swift"))
    subprocess.run(common + ["-module-name", module, "-emit-module", "-emit-module-path", str(out / f"{module}.swiftmodule"),
                   "-emit-library", "-static", "-o", str(out / f"lib{module}.a")] + list(map(str, sources)), check=True)
subprocess.run(common + ["-module-name", "NewtonApp", "-L", str(out), "-lNewtonCore", "-lNewtonLocal",
               "-framework", "llama", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
               "-o", str(out / "Newton")] + list(map(str, sorted((root / "App/Newton").glob("*.swift")))), check=True)
print(f"All {sdk_name} sources compiled and linked. Output:", out / "Newton")

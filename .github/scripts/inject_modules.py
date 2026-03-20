#!/usr/bin/env python3
"""Inject extra kernel modules into Bazel BUILD.bazel module_outs lists."""
import re
import sys

BUILD_FILE = sys.argv[1] if len(sys.argv) > 1 else "./common/BUILD.bazel"

EXTRA_MODULES = [
    "net/ipv4/tcp_bic.ko",
    "net/ipv4/tcp_htcp.ko",
    "net/ipv4/tcp_westwood.ko",
]

content = open(BUILD_FILE).read()

# Check if already injected
if all(mod in content for mod in EXTRA_MODULES):
    print("Extra modules already present in BUILD.bazel, skipping.")
    sys.exit(0)

# Build the insertion string
insert = ",\n        ".join(f'"{mod}"' for mod in EXTRA_MODULES)

# Replace every module_outs = [ with module_outs = [ + extras
content = re.sub(
    r'(module_outs\s*=\s*\[)',
    r'\1\n        ' + insert + ',',
    content,
)

open(BUILD_FILE, "w").write(content)
print(f"Injected {len(EXTRA_MODULES)} extra modules into {BUILD_FILE}")

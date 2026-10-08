#!/usr/bin/env python3
"""Verify release metadata, the archive signature, and the signed feed."""
import pathlib
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

feed, archive = map(pathlib.Path, sys.argv[1:3])
build = sys.argv[3]
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(feed).getroot()
items = root.findall("./channel/item")
matching = [item.find("enclosure") for item in items if item.findtext(namespace + "version") == build]
if len(matching) != 1:
    raise SystemExit("Expected exactly one entry for this build")
entry = matching[0]
assert entry.get("length") == str(archive.stat().st_size), "Archive length mismatch"
assert entry.get("url", "").startswith("https://github.com/"), "Downloads must use HTTPS"
assert entry.get("url", "").endswith("/" + archive.name), "Download filename mismatch"
signature = entry.get(namespace + "edSignature")
assert signature, "Missing EdDSA signature"
with zipfile.ZipFile(archive) as zipped:
    info = plistlib.loads(zipped.read("Voidamp.app/Contents/Info.plist"))
assert info["CFBundleVersion"] == build, "Bundle build mismatch"
assert info["SUPublicEDKey"] == pathlib.Path("updates/public-key.txt").read_text().strip(), "Signing key mismatch"
assert info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"]
assert "Voidamp.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" in zipped.namelist(), "Sparkle is missing"
tool = ".build/artifacts/sparkle/Sparkle/bin/sign_update"
subprocess.run([tool, "--account", "app.voidamp.mac.updates", "--verify", str(archive), signature], check=True)
subprocess.run([tool, "--account", "app.voidamp.mac.updates", "--verify", str(feed)], check=True)
print("PASS: bundle metadata, archive EdDSA signature, signed appcast, embedded Sparkle")

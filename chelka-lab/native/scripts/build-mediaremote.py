#!/usr/bin/env python3
"""Offline local build of pinned upstream Objective-C and the Forelock host."""
from pathlib import Path
import hashlib,json,platform,plistlib,re,subprocess,sys
root=Path(__file__).resolve().parents[1]
source=root/'Vendor/MediaRemoteAdapter'
manifest=json.loads((source/'UPSTREAM.json').read_text())
assert manifest['revision']=='0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd'
for name,digest in manifest['files'].items():
    if hashlib.sha256((source/name).read_bytes()).hexdigest()!=digest: raise SystemExit('Upstream source changed: '+name)
fw=Path(sys.argv[1]);version=fw/'Versions/A';(version/'Resources').mkdir(parents=True,exist_ok=True)
files=re.search(r'set\(ADAPTER_SOURCES\s+(.*?)\)',(source/'CMakeLists.txt').read_text(),re.S).group(1).split()
cmd=['xcrun','clang','-dynamiclib','-fobjc-arc','-fvisibility=default','-arch',platform.machine(),'-mmacosx-version-min=14.0','-I'+str(source/'include'),'-I'+str(source/'src')]
cmd += [str(source/name) for name in files]+[str(root/'MediaRemote/ForelockHost.m')]
cmd += ['-framework','Foundation','-framework','AppKit','-framework','UniformTypeIdentifiers','-framework','ImageIO','-install_name','@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter','-o',str(version/'MediaRemoteAdapter')]
subprocess.run(cmd,check=True)
(version/'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.vandenbe.MediaRemoteAdapter','CFBundleName':'MediaRemoteAdapter','CFBundleExecutable':'MediaRemoteAdapter','CFBundlePackageType':'FMWK','CFBundleVersion':'0.1.0','CFBundleShortVersionString':'0.1'}))
for link,target in [(fw/'Versions/Current','A'),(fw/'MediaRemoteAdapter','Versions/Current/MediaRemoteAdapter'),(fw/'Resources','Versions/Current/Resources')]:
    if not link.is_symlink():link.symlink_to(target)
subprocess.run(['codesign','--force','--sign','-',str(fw)],check=True)

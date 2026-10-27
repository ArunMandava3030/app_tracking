"""Local configuration check; this does not compile or run iOS code."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
with (root / 'Runner' / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert info['UIBackgroundModes'] == ['location']
assert info['NSLocationWhenInUseUsageDescription'].strip()
assert info['NSLocationAlwaysAndWhenInUseUsageDescription'].strip()
assert 'NSAppTransportSecurity' not in info
scene = info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]
assert scene['UISceneDelegateClassName'] == '$(PRODUCT_MODULE_NAME).SceneDelegate'
assert 'class SceneDelegate: FlutterSceneDelegate' in (root / 'Runner' / 'SceneDelegate.swift').read_text()
project = (root / 'Runner.xcodeproj' / 'project.pbxproj').read_text()
targets = re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);', project)
assert targets and all(float(value) >= 15 for value in targets), targets
for source in ('AppDelegate.swift', 'SceneDelegate.swift', 'GeneratedPluginRegistrant.m'):
    assert f'{source} in Sources' in project
    assert (root / 'Runner' / source).is_file()
assert 'com.apple.BackgroundModes' in project
native = (root / 'Runner' / 'AppDelegate.swift').read_text()
assert 'FlutterImplicitEngineDelegate' in native
assert 'engineBridge.applicationRegistrar.messenger()' in native
for source in root.rglob('*.plist'):
    with source.open('rb') as handle:
        plistlib.load(handle)
for source in (root / 'Runner' / 'Base.lproj').glob('*.storyboard'):
    ET.parse(source)
print('iOS configuration checks passed: plist XML, scene lifecycle, sources, background mode, iOS 15 deployment target.')
print('Swift compilation and physical iPhone behavior are not verified by this check.')

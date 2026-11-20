#!/usr/bin/env python3
"""Run the production Markdown view in an isolated iOS Simulator UI harness.

macOS/Xcode required. No signing, server connection, or app credentials needed.
Usage: python3 scripts/test-chat-selection.py <simulator-udid>
"""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
folder = root / 'Build' / 'ChatSelectionTests'
project = folder / 'Selection.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
objects = {}


def item(kind, **fields):
    key = f'{len(objects) + 1:024X}'
    objects[key] = dict(isa=kind, **fields)
    return key


def config(settings):
    return item('XCConfigurationList', buildConfigurations=[
        item('XCBuildConfiguration', name='Debug', buildSettings=settings)
    ], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')


def files(paths):
    references = [item('PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(root / p), sourceTree='<absolute>') for p in paths]
    phase = item('PBXSourcesBuildPhase', buildActionMask=2147483647,
                 files=[item('PBXBuildFile', fileRef=f) for f in references], runOnlyForDeploymentPostprocessing=0)
    return references, phase


common = dict(SDKROOT='iphonesimulator', IPHONEOS_DEPLOYMENT_TARGET='17.0', SWIFT_VERSION='5.0', ALWAYS_SEARCH_USER_PATHS='NO',
              CODE_SIGNING_ALLOWED='NO', GENERATE_INFOPLIST_FILE='YES', TARGETED_DEVICE_FAMILY='1,2',
              SWIFT_OPTIMIZATION_LEVEL='-Onone')
app_refs, app_sources = files(['Tests/ChatSelection/Harness.swift', 'iFilePlus/Services/ChatMarkdown.swift', 'iFilePlus/Views/CodexMarkdownView.swift'])
app_product = item('PBXFileReference', explicitFileType='wrapper.application', path='Selection.app', sourceTree='BUILT_PRODUCTS_DIR')
app = item('PBXNativeTarget', name='Selection', productName='Selection', productReference=app_product,
           productType='com.apple.product-type.application', buildPhases=[app_sources], buildRules=[], dependencies=[],
           buildConfigurationList=config(dict(common, PRODUCT_NAME='Selection', PRODUCT_BUNDLE_IDENTIFIER='local.astrogate.selection-test',
               INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES', INFOPLIST_KEY_UILaunchScreen_Generation='YES')))
ui_refs, ui_sources = files(['Tests/ChatSelection/SelectionUITests.swift'])
ui_product = item('PBXFileReference', explicitFileType='wrapper.cfbundle', path='SelectionUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
ui = item('PBXNativeTarget', name='SelectionUITests', productName='SelectionUITests', productReference=ui_product,
          productType='com.apple.product-type.bundle.ui-testing', buildPhases=[ui_sources], buildRules=[],
          dependencies=[item('PBXTargetDependency', target=app)],
          buildConfigurationList=config(dict(common, PRODUCT_NAME='SelectionUITests', PRODUCT_BUNDLE_IDENTIFIER='local.astrogate.selection-uitests', TEST_TARGET_NAME='Selection')))
group = item('PBXGroup', children=app_refs + ui_refs + [app_product, ui_product], sourceTree='<group>')
project_id = item('PBXProject', attributes={'LastUpgradeCheck': '2600', 'TargetAttributes': {ui: {'TestTargetID': app}}},
                  buildConfigurationList=config(common), compatibilityVersion='Xcode 14.0', developmentRegion='en',
                  hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=group, projectDirPath='', projectRoot='', targets=[app, ui])


def encode(value):
    if isinstance(value, dict):
        return '{' + ''.join(f'{json.dumps(k)} = {encode(v)};' for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '(' + ','.join(encode(v) for v in value) + ')'
    return json.dumps(value)


(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project_id)))
scheme_dir = project / 'xcshareddata' / 'xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)


def reference(key, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Selection.xcodeproj"/>'


(scheme_dir / 'Selection.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference(app, 'Selection.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference(ui, 'SelectionUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference(app, 'Selection.app')}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
subprocess.run(['xcodebuild', '-quiet', '-project', str(project), '-scheme', 'Selection',
                '-destination', f'platform=iOS Simulator,id={sys.argv[1]}', '-derivedDataPath', str(folder / 'DerivedData'),
                '-parallel-testing-enabled', 'NO', 'test'], check=True, cwd=root)

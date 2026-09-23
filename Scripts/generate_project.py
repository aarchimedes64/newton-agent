#!/usr/bin/env python3
"""Generate the checked-in Xcode project without third-party tooling."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, body):
    objects[ident(name)] = body
    return ident(name)
def seq(values): return '(' + ','.join(values) + ',)'
sources, refs = [], []
for file in sorted((root / 'App/Newton').glob('*.swift')):
    ref = add(str(file.relative_to(root)), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{file.relative_to(root)}"; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    sources.append(add('build'+file.name, f'isa = PBXBuildFile; fileRef = {ref};'))
privacy = add('privacy', 'isa = PBXFileReference; lastKnownFileType = text.xml; path = App/Resources/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT;')
refs.append(privacy)
resource = add('privacyBuild', f'isa = PBXBuildFile; fileRef = {privacy};')
product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Newton.app; sourceTree = BUILT_PRODUCTS_DIR;')
package = add('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
products, links = [], []
for name in ['NewtonCore', 'NewtonLocal']:
    p = add(name, f'isa = XCSwiftPackageProductDependency; productName = {name};')
    products.append(p)
    links.append(add(name+'link', f'isa = PBXBuildFile; productRef = {p};'))
sp = add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {seq(sources)}; runOnlyForDeploymentPostprocessing = 0;')
fp = add('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {seq(links)}; runOnlyForDeploymentPostprocessing = 0;')
rp = add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {seq([resource])}; runOnlyForDeploymentPostprocessing = 0;')
pg = add('products', f'isa = PBXGroup; children = {seq([product])}; name = Products; sourceTree = "<group>";')
main = add('main', f'isa = PBXGroup; children = {seq(refs+[pg])}; sourceTree = "<group>";')
pc, tc = [], []
for config in ['Debug', 'Release']:
    opt = '-Onone' if config == 'Debug' else '-O'
    pc.append(add('project'+config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "{opt}"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; }};'))
    tc.append(add('target'+config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ PRODUCT_NAME = Newton; PRODUCT_BUNDLE_IDENTIFIER = com.newton.agent; INFOPLIST_FILE = App/Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGN_STYLE = Automatic; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; ENABLE_USER_SCRIPT_SANDBOXING = YES; }};'))
pcl = add('projectConfigs', f'isa = XCConfigurationList; buildConfigurations = {seq(pc)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tcl = add('targetConfigs', f'isa = XCConfigurationList; buildConfigurations = {seq(tc)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = add('target', f'isa = PBXNativeTarget; buildConfigurationList = {tcl}; buildPhases = {seq([sp,fp,rp])}; buildRules = (); dependencies = (); name = Newton; packageProductDependencies = {seq(products)}; productName = Newton; productReference = {product}; productType = "com.apple.product-type.application";')
project = add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; }}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; packageReferences = {seq([package])}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = {seq([target])};')
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'
text += '\n'.join(f'{key} = {{ {body} }};' for key, body in objects.items())
text += f'\n}}; rootObject = {project}; }}\n'
(root/'Newton.xcodeproj/project.pbxproj').write_text(text)
(root/'Newton.xcodeproj/xcshareddata/xcschemes/Newton.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Newton.app" BlueprintName="Newton" ReferencedContainer="container:Newton.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Newton.app" BlueprintName="Newton" ReferencedContainer="container:Newton.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated Newton.xcodeproj')

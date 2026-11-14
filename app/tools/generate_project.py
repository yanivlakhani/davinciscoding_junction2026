"""Generate the small Xcode project with only Python's standard library."""
import hashlib
from pathlib import Path
import plistlib
import json

root = Path(__file__).resolve().parents[1] / "ios"
project = root / "FallApp.xcodeproj"
project.mkdir(exist_ok=True)
objects = {}


def add(identity, **value):
    key = hashlib.sha256(identity.encode()).hexdigest()[:24].upper()
    objects[key] = value
    return key


sources = []
references = []
for path in sorted((root / "FallApp").glob("*.swift")):
    ref = add("ref:" + path.name, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
    references.append(ref)
    sources.append(add("build:" + path.name, isa="PBXBuildFile", fileRef=ref))
info = add("info", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>")
assets = add("assets", isa="PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="<group>")
asset_build = add("asset-build", isa="PBXBuildFile", fileRef=assets)
app_group = add("app-group", isa="PBXGroup", children=references + [info, assets], path="FallApp", sourceTree="<group>")
product = add("product", isa="PBXFileReference", explicitFileType="wrapper.application", path="FallApp.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", isa="PBXGroup", name="Products", children=[product], sourceTree="<group>")
config_file = add("config-file", isa="PBXFileReference", lastKnownFileType="text.xcconfig", path="Configuration/App.xcconfig", sourceTree="<group>")
group = add("root-group", isa="PBXGroup", children=[app_group, config_file, products], sourceTree="<group>")
sdk = add("meta-sdk", isa="XCRemoteSwiftPackageReference", repositoryURL="https://github.com/facebook/meta-wearables-dat-ios",
          requirement={"kind": "exactVersion", "version": "1.0.1"})
local = add("local-package", isa="XCLocalSwiftPackageReference", relativePath="../packages/DetectionEngine")
dependencies, frameworks = [], []
for name, package in [("MWDATCore", sdk), ("MWDATMotion", sdk), ("MWDATCamera", sdk), ("DetectionEngine", local)]:
    ref = add("dependency:" + name, isa="XCSwiftPackageProductDependency", package=package, productName=name)
    dependencies.append(ref)
    frameworks.append(add("framework:" + name, isa="PBXBuildFile", productRef=ref))
source_phase = add("sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
resource_phase = add("resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=[asset_build], runOnlyForDeploymentPostprocessing=0)
framework_phase = add("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=frameworks, runOnlyForDeploymentPostprocessing=0)
target_config, project_config = [], []
for name in ("Debug", "Release"):
    settings = {"CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "10", "MARKETING_VERSION": "0.1.0",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "INFOPLIST_FILE": "FallApp/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "SWIFT_VERSION": "6.0",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.2", "TARGETED_DEVICE_FAMILY": "1", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SWIFT_STRICT_CONCURRENCY": "complete",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if name == "Debug" else "",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "CLANG_ENABLE_MODULES": "YES"}
    target_config.append(add("target:" + name, isa="XCBuildConfiguration", baseConfigurationReference=config_file, buildSettings=settings, name=name))
    project_config.append(add("project:" + name, isa="XCBuildConfiguration", buildSettings={"CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "6.0"}, name=name))
target_list = add("target-configs", isa="XCConfigurationList", buildConfigurations=target_config, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
project_list = add("project-configs", isa="XCConfigurationList", buildConfigurations=project_config, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target = add("app-target", isa="PBXNativeTarget", buildConfigurationList=target_list,
             buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[], name="FallApp",
             packageProductDependencies=dependencies, productName="FallApp", productReference=product,
             productType="com.apple.product-type.application")
main = add("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2640"}, buildConfigurationList=project_list,
           compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
           mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", packageReferences=[sdk, local], targets=[target])


def emit(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(key) + " = " + emit(item, level + 1) + ";\n" for key, item in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(emit(item, level) for item in value) + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)


(project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + emit({"archiveVersion": 1, "classes": {}, "objectVersion": 56,
    "objects": objects, "rootObject": main}) + "\n")
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "FallApp.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2640" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="FallApp.app" BlueprintName="FallApp" ReferencedContainer="container:FallApp.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="FallApp.app" BlueprintName="FallApp" ReferencedContainer="container:FallApp.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
info_value = {"CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "FallApp", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "CFBundleURLTypes": [{"CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleURLSchemes": ["fallapp"]}],
    "MWDAT": {"AppLinkURLScheme": "fallapp://", "MetaAppID": "$(META_APP_ID)", "ClientToken": "$(CLIENT_TOKEN)", "TeamID": "$(DEVELOPMENT_TEAM)"},
    "NSBluetoothAlwaysUsageDescription": "Connect to your Meta glasses for local fall monitoring.",
    "NSCameraUsageDescription": "Capture one-second image bursts from your glasses after a fall alert.",
    "NSLocalNetworkUsageDescription": "Connect to your Meta glasses over the local network.",
    "NSBonjourServices": ["_bonjour._tcp"], "UIBackgroundModes": ["bluetooth-central", "bluetooth-peripheral", "external-accessory"],
    "UISupportedExternalAccessoryProtocols": ["com.meta.ar.wearable"], "UILaunchScreen": {},
    "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"], "UIUserInterfaceStyle": "Light",
    "ModalEndpointURL": "$(MODAL_ENDPOINT_URL)", "ModalAuthMode": "$(MODAL_AUTH_MODE)"}
(root / "FallApp/Info.plist").write_bytes(plistlib.dumps(info_value))
assets_root = root / "FallApp/Assets.xcassets"
assets_root.mkdir(exist_ok=True)
(assets_root / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
logo = assets_root / "MetaLogo.imageset"
logo.mkdir(exist_ok=True)
(logo / "Contents.json").write_text(json.dumps({"images": [{"filename": "meta-logo.svg", "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
    "properties": {"preserves-vector-representation": True, "template-rendering-intent": "original"}}, indent=2))
print("Generated ios/FallApp.xcodeproj and Info.plist")

#!/usr/bin/env python3
"""
patch_pbxproj.py
================
Adds the GopeedWidgets extension target and wires the three new Runner
Swift files into the existing project.pbxproj WITHOUT requiring Xcode.

Run from repo root:
    python3 scripts/patch_pbxproj.py

Idempotent: re-running after a successful patch is safe (detects existing IDs).
"""

import re, sys, os, textwrap
from pathlib import Path

PBXPROJ = Path("ui/flutter/ios/Runner.xcodeproj/project.pbxproj")

# ── Stable UUIDs (generated once, hardcoded so the patch is idempotent) ──────
# Runner new files
UID_BDM_FILE    = "AA000001000000000000AAA1"   # BackgroundDownloadManager.swift fileRef
UID_BDM_BUILD   = "AA000001000000000000AAA2"   # … in Sources
UID_LAB_FILE    = "AA000001000000000000AAA3"   # LiveActivityBridge.swift fileRef
UID_LAB_BUILD   = "AA000001000000000000AAA4"   # … in Sources
UID_DAA_RUNNER_FILE  = "AA000001000000000000AAA5"  # DownloadActivityAttributes.swift (Runner copy)
UID_DAA_RUNNER_BUILD = "AA000001000000000000AAA6"

# GopeedWidgets extension
UID_GW_GROUP        = "BB000001000000000000BBB1"  # PBXGroup for GopeedWidgets folder
UID_GW_APPEX        = "BB000001000000000000BBB2"  # PBXFileReference .appex product
UID_GW_TARGET       = "BB000001000000000000BBB3"  # PBXNativeTarget
UID_GW_PROXY        = "BB000001000000000000BBB4"  # PBXContainerItemProxy
UID_GW_DEP          = "BB000001000000000000BBB5"  # PBXTargetDependency
UID_GW_SOURCES_PH   = "BB000001000000000000BBB6"  # PBXSourcesBuildPhase
UID_GW_FRAMES_PH    = "BB000001000000000000BBB7"  # PBXFrameworksBuildPhase
UID_GW_RES_PH       = "BB000001000000000000BBB8"  # PBXResourcesBuildPhase
UID_GW_EMBED_PH     = "BB000001000000000000BBB9"  # CopyFiles Embed Extensions (in Runner)

UID_WIDGET_FILE     = "BB000001000000000000BBBA"  # GopeedDownloadWidget.swift
UID_WIDGET_BUILD    = "BB000001000000000000BBBB"
UID_BUNDLE_FILE     = "BB000001000000000000BBBC"  # GopeedWidgetsBundle.swift
UID_BUNDLE_BUILD    = "BB000001000000000000BBBD"
UID_DAA_GW_FILE     = "BB000001000000000000BBBE"  # DownloadActivityAttributes.swift (widget copy)
UID_DAA_GW_BUILD    = "BB000001000000000000BBBF"
UID_GW_INFO_FILE    = "BB000001000000000000BBB0"  # GopeedWidgets/Info.plist fileRef

UID_GW_CFG_LIST     = "CC000001000000000000CCC1"  # XCConfigurationList for GopeedWidgets
UID_GW_CFG_DEBUG    = "CC000001000000000000CCC2"
UID_GW_CFG_RELEASE  = "CC000001000000000000CCC3"
UID_GW_CFG_PROFILE  = "CC000001000000000000CCC4"

# Runner embed phase for the widget appex
UID_GW_EMBED_BUILD  = "CC000001000000000000CCC5"  # GopeedWidgets.appex in Embed phase

BUNDLE_ID_WIDGETS = "com.gopeed.gopeed.GopeedWidgets"
DEPLOY_TARGET = "16.2"   # minimum for Live Activities

def bail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

def already_patched(content: str) -> bool:
    return UID_BDM_FILE in content

def load():
    if not PBXPROJ.exists():
        bail(f"Not found: {PBXPROJ}")
    return PBXPROJ.read_text(encoding="utf-8")

def save(content: str):
    PBXPROJ.write_text(content, encoding="utf-8")
    print(f"Written: {PBXPROJ}")

# ── Section inserters ─────────────────────────────────────────────────────────

def insert_after(content: str, anchor: str, insertion: str) -> str:
    idx = content.find(anchor)
    if idx == -1:
        bail(f"Anchor not found: {anchor!r}")
    insert_at = idx + len(anchor)
    return content[:insert_at] + insertion + content[insert_at:]

def replace_first(content: str, old: str, new: str) -> str:
    if old not in content:
        bail(f"Replace anchor not found: {old!r}")
    return content.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────

def patch(content: str) -> str:

    # ── 1. PBXBuildFile — new entries ─────────────────────────────────────────
    new_build_files = f"""
\t\t{UID_BDM_BUILD} /* BackgroundDownloadManager.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {UID_BDM_FILE} /* BackgroundDownloadManager.swift */; }};
\t\t{UID_LAB_BUILD} /* LiveActivityBridge.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {UID_LAB_FILE} /* LiveActivityBridge.swift */; }};
\t\t{UID_DAA_RUNNER_BUILD} /* DownloadActivityAttributes.swift (Runner) in Sources */ = {{isa = PBXBuildFile; fileRef = {UID_DAA_RUNNER_FILE} /* DownloadActivityAttributes.swift */; }};
\t\t{UID_WIDGET_BUILD} /* GopeedDownloadWidget.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {UID_WIDGET_FILE} /* GopeedDownloadWidget.swift */; }};
\t\t{UID_BUNDLE_BUILD} /* GopeedWidgetsBundle.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {UID_BUNDLE_FILE} /* GopeedWidgetsBundle.swift */; }};
\t\t{UID_DAA_GW_BUILD} /* DownloadActivityAttributes.swift (GopeedWidgets) in Sources */ = {{isa = PBXBuildFile; fileRef = {UID_DAA_GW_FILE} /* DownloadActivityAttributes.swift */; }};
\t\t{UID_GW_EMBED_BUILD} /* GopeedWidgets.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {UID_GW_APPEX} /* GopeedWidgets.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
"""
    content = insert_after(content, "/* Begin PBXBuildFile section */", new_build_files)

    # ── 2. PBXContainerItemProxy for GopeedWidgets ────────────────────────────
    new_proxy = f"""
\t\t{UID_GW_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 97C146E61CF9000F007C117D /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {UID_GW_TARGET};
\t\t\tremoteInfo = GopeedWidgets;
\t\t}};
"""
    content = insert_after(content, "/* Begin PBXContainerItemProxy section */", new_proxy)

    # ── 3. Add GopeedWidgets.appex to existing Embed Foundation Extensions ─────
    # The existing phase already has ShareExtension.appex — add ours too
    content = replace_first(
        content,
        "\t\t\t\t0C585CC12D41E28900FF2EC0 /* ShareExtension.appex in Embed Foundation Extensions */,",
        f"\t\t\t\t0C585CC12D41E28900FF2EC0 /* ShareExtension.appex in Embed Foundation Extensions */,\n\t\t\t\t{UID_GW_EMBED_BUILD} /* GopeedWidgets.appex in Embed Foundation Extensions */,"
    )

    # ── 4. PBXFileReference — new source files ────────────────────────────────
    new_file_refs = f"""
\t\t{UID_BDM_FILE} /* BackgroundDownloadManager.swift */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = BackgroundDownloadManager.swift; sourceTree = "<group>"; }};
\t\t{UID_LAB_FILE} /* LiveActivityBridge.swift */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = LiveActivityBridge.swift; sourceTree = "<group>"; }};
\t\t{UID_DAA_RUNNER_FILE} /* DownloadActivityAttributes.swift (Runner) */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; name = DownloadActivityAttributes.swift; path = Shared/DownloadActivityAttributes.swift; sourceTree = "<group>"; }};
\t\t{UID_GW_APPEX} /* GopeedWidgets.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = GopeedWidgets.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{UID_WIDGET_FILE} /* GopeedDownloadWidget.swift */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = GopeedDownloadWidget.swift; sourceTree = "<group>"; }};
\t\t{UID_BUNDLE_FILE} /* GopeedWidgetsBundle.swift */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = GopeedWidgetsBundle.swift; sourceTree = "<group>"; }};
\t\t{UID_DAA_GW_FILE} /* DownloadActivityAttributes.swift (GopeedWidgets) */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; name = DownloadActivityAttributes.swift; path = ../Shared/DownloadActivityAttributes.swift; sourceTree = "<group>"; }};
\t\t{UID_GW_INFO_FILE} /* GopeedWidgets/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
"""
    content = insert_after(content, "/* Begin PBXFileReference section */", new_file_refs)

    # ── 5. PBXGroup — add new source files to Runner group ───────────────────
    content = replace_first(
        content,
        "\t\t\t\t74858FAD1ED2DC5600515810 /* Runner-Bridging-Header.h */,",
        f"\t\t\t\t74858FAD1ED2DC5600515810 /* Runner-Bridging-Header.h */,\n\t\t\t\t{UID_BDM_FILE} /* BackgroundDownloadManager.swift */,\n\t\t\t\t{UID_LAB_FILE} /* LiveActivityBridge.swift */,\n\t\t\t\t{UID_DAA_RUNNER_FILE} /* DownloadActivityAttributes.swift */,"
    )

    # Add GopeedWidgets group + product to top-level group
    content = replace_first(
        content,
        "\t\t\t\t97C146EF1CF9000F007C117D /* Products */,",
        f"\t\t\t\t97C146EF1CF9000F007C117D /* Products */,\n\t\t\t\t{UID_GW_GROUP} /* GopeedWidgets */,"
    )

    # GopeedWidgets group definition
    new_gw_group = f"""
\t\t{UID_GW_GROUP} /* GopeedWidgets */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{UID_WIDGET_FILE} /* GopeedDownloadWidget.swift */,
\t\t\t\t{UID_BUNDLE_FILE} /* GopeedWidgetsBundle.swift */,
\t\t\t\t{UID_DAA_GW_FILE} /* DownloadActivityAttributes.swift */,
\t\t\t\t{UID_GW_INFO_FILE} /* Info.plist */,
\t\t\t);
\t\t\tpath = GopeedWidgets;
\t\t\tsourceTree = "<group>";
\t\t}};
"""
    content = insert_after(content, "/* Begin PBXGroup section */", new_gw_group)

    # Add GopeedWidgets.appex to Products group
    content = replace_first(
        content,
        "\t\t\t\t0C585CB72D41E28900FF2EC0 /* ShareExtension.appex */,",
        f"\t\t\t\t0C585CB72D41E28900FF2EC0 /* ShareExtension.appex */,\n\t\t\t\t{UID_GW_APPEX} /* GopeedWidgets.appex */,"
    )

    # ── 6. PBXNativeTarget — GopeedWidgets ────────────────────────────────────
    new_target = f"""
\t\t{UID_GW_TARGET} /* GopeedWidgets */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {UID_GW_CFG_LIST} /* Build configuration list for PBXNativeTarget "GopeedWidgets" */;
\t\t\tbuildPhases = (
\t\t\t\t{UID_GW_SOURCES_PH} /* Sources */,
\t\t\t\t{UID_GW_FRAMES_PH} /* Frameworks */,
\t\t\t\t{UID_GW_RES_PH} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = GopeedWidgets;
\t\t\tproductName = GopeedWidgets;
\t\t\tproductReference = {UID_GW_APPEX} /* GopeedWidgets.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};
"""
    content = insert_after(content, "/* Begin PBXNativeTarget section */", new_target)

    # ── 7. Add GopeedWidgets as a dependency of Runner ────────────────────────
    content = replace_first(
        content,
        "\t\t\t\t0C585CC02D41E28900FF2EC0 /* PBXTargetDependency */,",
        f"\t\t\t\t0C585CC02D41E28900FF2EC0 /* PBXTargetDependency */,\n\t\t\t\t{UID_GW_DEP} /* PBXTargetDependency */,"
    )

    # ── 8. PBXProject — register target & attributes ──────────────────────────
    # TargetAttributes uses 5-tab indent (^I^I^I^I^I) for entry IDs
    content = replace_first(
        content,
        "\t\t\t\t\t0C585CB62D41E28900FF2EC0 = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.4;\n\t\t\t\t\t};",
        f"\t\t\t\t\t0C585CB62D41E28900FF2EC0 = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.4;\n\t\t\t\t\t}};\n\t\t\t\t\t{UID_GW_TARGET} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.4;\n\t\t\t\t\t}};"
    )
    # targets array uses 3-tab indent
    content = replace_first(
        content,
        "\t\t\t\t97C146ED1CF9000F007C117D /* Runner */,\n\t\t\t\t0C585CB62D41E28900FF2EC0 /* ShareExtension */,",
        f"\t\t\t\t97C146ED1CF9000F007C117D /* Runner */,\n\t\t\t\t0C585CB62D41E28900FF2EC0 /* ShareExtension */,\n\t\t\t\t{UID_GW_TARGET} /* GopeedWidgets */,"
    )

    # ── 9. PBXSourcesBuildPhase — add new files to Runner Sources ─────────────
    content = replace_first(
        content,
        "\t\t\t\t74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,",
        f"\t\t\t\t74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,\n\t\t\t\t{UID_BDM_BUILD} /* BackgroundDownloadManager.swift in Sources */,\n\t\t\t\t{UID_LAB_BUILD} /* LiveActivityBridge.swift in Sources */,\n\t\t\t\t{UID_DAA_RUNNER_BUILD} /* DownloadActivityAttributes.swift in Sources */,"
    )

    # GopeedWidgets Sources build phase
    new_gw_sources = f"""
\t\t{UID_GW_SOURCES_PH} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{UID_WIDGET_BUILD} /* GopeedDownloadWidget.swift in Sources */,
\t\t\t\t{UID_BUNDLE_BUILD} /* GopeedWidgetsBundle.swift in Sources */,
\t\t\t\t{UID_DAA_GW_BUILD} /* DownloadActivityAttributes.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{UID_GW_FRAMES_PH} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{UID_GW_RES_PH} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
    content = insert_after(content, "/* Begin PBXSourcesBuildPhase section */", new_gw_sources)

    # ── 10. PBXTargetDependency for GopeedWidgets ─────────────────────────────
    new_dep = f"""
\t\t{UID_GW_DEP} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {UID_GW_TARGET} /* GopeedWidgets */;
\t\t\ttargetProxy = {UID_GW_PROXY} /* PBXContainerItemProxy */;
\t\t}};
"""
    content = insert_after(content, "/* Begin PBXTargetDependency section */", new_dep)

    # ── 11. XCBuildConfiguration for GopeedWidgets ───────────────────────────
    gw_cfg_common = (
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n"
        "\t\t\t\tCLANG_ENABLE_MODULES = YES;\n"
        f"\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
        "\t\t\t\tDEVELOPMENT_TEAM = JH48DS925K;\n"
        "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n"
        f"\t\t\t\tINFOPLIST_FILE = GopeedWidgets/Info.plist;\n"
        f"\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {DEPLOY_TARGET};\n"
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n"
        "\t\t\t\t\t\"$(inherited)\",\n"
        "\t\t\t\t\t\"@executable_path/Frameworks\",\n"
        "\t\t\t\t\t\"@executable_path/../../Frameworks\",\n"
        "\t\t\t\t);\n"
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID_WIDGETS};\n"
        "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n"
        "\t\t\t\tSKIP_INSTALL = YES;\n"
        "\t\t\t\tSWIFT_VERSION = 5.0;\n"
        "\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";\n"
    )

    new_cfg = f"""
\t\t{UID_GW_CFG_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{gw_cfg_common}\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{UID_GW_CFG_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{gw_cfg_common}\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{UID_GW_CFG_PROFILE} /* Profile */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{gw_cfg_common}\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t}};
\t\t\tname = Profile;
\t\t}};
"""
    content = insert_after(content, "/* Begin XCBuildConfiguration section */", new_cfg)

    # ── 12. XCConfigurationList for GopeedWidgets ─────────────────────────────
    new_cfg_list = f"""
\t\t{UID_GW_CFG_LIST} /* Build configuration list for PBXNativeTarget "GopeedWidgets" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{UID_GW_CFG_DEBUG} /* Debug */,
\t\t\t\t{UID_GW_CFG_RELEASE} /* Release */,
\t\t\t\t{UID_GW_CFG_PROFILE} /* Profile */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
"""
    content = insert_after(content, "/* Begin XCConfigurationList section */", new_cfg_list)

    return content


def main():
    content = load()
    if already_patched(content):
        print("project.pbxproj already patched — nothing to do.")
        return
    content = patch(content)
    save(content)
    print("✅  project.pbxproj patched successfully.")
    print()
    print("Next steps:")
    print("  1. Push this commit — GitHub Actions will pick it up.")
    print("  2. On first run, xcodebuild will see the new target.")
    print("  3. Check the Actions log for any pbxproj-related build errors.")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Offline Termux V2 upgrade regressions (Python stdlib + Node + git).

Run: python3 scripts/test-v2-upgrade.py --evidence-root <saved-inspection-dir>
Requires pristine OpenCode/OpenTUI target files and npm-core JS there. No fetch,
install, build, native dlopen or full Effect service is performed. Each mutation
uses a fresh retained scratch directory under evidence-root/implementation-tests.
"""

import argparse
import fnmatch
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
EVIDENCE = None


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=30, **kwargs)


def scratch():
    base = EVIDENCE / "implementation-tests"
    base.mkdir(exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="case-", dir=base))


def heredoc(marker):
    script = (REPO / "scripts/build-opencode2.sh").read_text()
    match = re.search(r"^python3 [^\n]*<<'" + marker + r"'\n(.*?)\n" + marker + r"$", script, re.M | re.S)
    if not match:
        raise AssertionError(f"missing executable {marker} validation block")
    return match[1]


def runtime_block():
    script = (REPO / "scripts/build-opencode2.sh").read_text()
    match = re.search(r"^python3 - \"\$OPENCODE_SRC\" <<'PY'\n(.*?)\nPY$", script, re.M | re.S)
    if not match:
        raise AssertionError("runtime patch block missing")
    return match[1]


def copy_runtime():
    root = scratch()
    destination = root / "node_modules/@opentui/core"
    destination.mkdir(parents=True)
    for source in (EVIDENCE / "npm-core").glob("chunk-*.js"):
        shutil.copy2(source, destination / source.name)
    return root, destination


def runtime_patch(root):
    return run(["python3", "-", str(root)], input=runtime_block())


def workflow_push_tag_patterns(workflow):
    """Read the actual workflow's quoted block-list on.push.tags (no YAML dependency)."""
    match = re.search(r"^on:\n  push:\n    tags:\n((?:      [^\n]*\n)+)", workflow, re.M)
    if not match:
        raise AssertionError("missing block-list on.push.tags")
    patterns = []
    for line in match[1].splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        item = re.fullmatch(r"      - (['\"])([^'\"]+)\1(?:\s+#.*)?", line)
        if not item:
            raise AssertionError("unsupported tag-filter syntax; expected quoted list item")
        patterns.append(item[2])
    return patterns


def simulate_tag_push(patterns, tag):
    """LOCAL simulation only, NOT GitHub evaluation.

    fnmatchcase is used only for literal prefixes plus trailing *, and slash-free
    tags. No **, ?, character classes or GitHub-only glob constructs are modeled.
    Matching entries are processed in order: positive includes, !negative excludes.
    """
    if "/" in tag or not patterns or not any(not p.startswith("!") for p in patterns):
        raise AssertionError("unsupported simulation input")
    included = False
    for pattern in patterns:
        if not re.fullmatch(r"!?[A-Za-z0-9._-]+\*", pattern):
            raise AssertionError("unsupported simulation glob: " + pattern)
        negative = pattern.startswith("!")
        if fnmatch.fnmatchcase(tag, pattern.removeprefix("!")):
            included = not negative
    return included


def workflow_v2_job_predicate(workflow):
    job = workflow.split("  build-v2:\n", 1)[1]
    match = re.search(r"^    if: (.+)$", job, re.M)
    return match[1].strip() if match else None


def simulate_v2_job(predicate, event):
    """LOCAL simulation of only the approved simple event-name equality."""
    if predicate is None:
        return True  # Existing unguarded job is eligible for all triggering events.
    match = re.fullmatch(r"github\.event_name == '([a-z_]+)'", predicate)
    if not match:
        raise AssertionError("unsupported job predicate in local simulation")
    return event == match[1]


NODE_SELECTOR = r'''
const fs=require("node:fs"), vm=require("node:vm"), assert=require("node:assert/strict");
const input=JSON.parse(fs.readFileSync(0,"utf8"));
// Execute the real shared parseReleaseVersion/invalidComponent, stripping only TS syntax.
let source=input.shared.slice(input.shared.indexOf("const maximumComponent"));
source=source.slice(0,source.indexOf("export function action"))+
 input.shared.slice(input.shared.indexOf("export function parseReleaseVersion"),input.shared.indexOf("function sameRelease"))+
 input.shared.slice(input.shared.indexOf("function invalidComponent"));
source=source.replaceAll("export function", "function").replaceAll("input: string", "input").replaceAll("value: string", "value");
const context=vm.createContext({}); vm.runInContext(source+"\nthis.parseReleaseVersion=parseReleaseVersion",context);
const added=input.patch.split("\n").filter(l=>l.startsWith("+")&&!l.startsWith("+++")).map(l=>l.slice(1)).join("\n");
const start=added.indexOf("    const releases =")>=0?added.indexOf("    const releases ="):added.indexOf("    const rel =");
const end=added.indexOf("\n    if (!data)",start)>=0?added.indexOf("\n    if (!data)",start):added.indexOf("\n    if (!rel ||",start);
assert(start>=0&&end>=0,"selector anchors missing");
const code=added.slice(start,end);
const select=new Function("list","parseReleaseVersion",code+"\nreturn typeof data!=='undefined'?data:(typeof rel!=='undefined'&&rel&&version&&pkg?{package:pkg,version}:undefined);");
const actual=select(input.list,context.parseReleaseVersion);
process.stdout.write(JSON.stringify(actual??null));
'''


NODE_RUNTIME = r'''
const fs=require("node:fs"),vm=require("node:vm"),assert=require("node:assert/strict");
const input=JSON.parse(fs.readFileSync(0,"utf8"));
function fn(t,s){const a=t.indexOf(s),b=t.indexOf("\n}",a);assert(a>=0&&b>=0);return t.slice(a,b+2);}
async function check(text,patched){
 const code=fn(text,"function getNativeAssetDescriptor(target)")+"\n"+
 fn(text,"function getCurrentNodeAssetTarget()")+"\n"+fn(text,"async function resolveNativeLibraryPath()");
 const c=vm.createContext({process:{platform:"android",arch:"arm64",env:{OPENTUI_LIB_PATH:"/fixture/libopentui.so",OPENTUI_LIBC:"android"}},resolveAssetRootPath:()=>undefined});
 vm.runInContext('var NATIVE_FILE_NAMES={darwin:"libopentui.dylib",linux:"libopentui.so",win32:"opentui.dll"};\n'+code+'\nthis.api={getCurrentNodeAssetTarget,getNativeAssetDescriptor,resolveNativeLibraryPath};',c);
 if(!patched){await assert.rejects(c.api.resolveNativeLibraryPath(),/Unsupported OpenTUI Node asset target/);return;}
 assert.equal(await c.api.resolveNativeLibraryPath(),"/fixture/libopentui.so");
 assert.equal(c.api.getCurrentNodeAssetTarget().platform,"linux");
 assert.equal(c.api.getNativeAssetDescriptor(c.api.getCurrentNodeAssetTarget()).fileName,"libopentui.so");
}
(async()=>{await check(input.before,false);await check(input.after,true);console.log("actual distributed handlers: pristine rejection and patched override PASS");})().catch(e=>{console.error(e);process.exitCode=1});
'''


def release(tag="v2.0.27-android-rc1", names=None, draft=False):
    names = names if names is not None else ["opencode_1.18.27_aarch64.deb", "opencode_2.0.27_aarch64.deb"]
    return {"tag_name": tag, "draft": draft, "prerelease": True,
            "assets": [{"browser_download_url": "https://example.invalid/releases/" + tag + "/" + name} for name in names]}


class UpgradeTests(unittest.TestCase):
    def test_workflow_tag_push_filter_prevents_duplicate_v2_release_build(self):
        workflow = (REPO / ".github/workflows/build.yml").read_text()
        patterns = workflow_push_tag_patterns(workflow)
        for tag, expected in [("v2.0.27-android-rc1", False), ("v2.0.27", False),
                              ("v0.3.0-1.18.27-android-rc4", True), ("v1.19.0", True),
                              ("release-2.0.27", False)]:
            with self.subTest(local_simulation_tag=tag):
                self.assertEqual(simulate_tag_push(patterns, tag), expected)
        self.assertEqual(patterns, ["v*", "!v2.*"], "negative must follow legacy positive")

    def test_workflow_build_v2_is_manual_dispatch_only(self):
        workflow = (REPO / ".github/workflows/build.yml").read_text()
        predicate = workflow_v2_job_predicate(workflow)
        for event, expected in [("workflow_dispatch", True), ("push", False)]:
            with self.subTest(local_simulation_event=event):
                self.assertEqual(simulate_v2_job(predicate, event), expected)
        self.assertEqual(predicate, "github.event_name == 'workflow_dispatch'")

    def select(self, releases):
        result = run(["node", "-e", NODE_SELECTOR], input=json.dumps({
            "patch": (REPO / "patches/opencode2/updater-android-channel.patch").read_text(),
            "shared": (EVIDENCE / "opencode/packages/cli/src/services/updater-action.ts").read_text(),
            "list": releases,
        }))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_selector_mixed_assets(self):
        for names in [["opencode_1.18.27_aarch64.deb", "opencode_2.0.27_aarch64.deb"],
                      ["opencode_2.0.27_aarch64.deb", "opencode_1.18.27_aarch64.deb"]]:
            with self.subTest(order=names):
                selected = self.select([release(names=names)])
                self.assertEqual(selected["version"], "2.0.27")
                self.assertTrue(selected["package"].endswith("/opencode_2.0.27_aarch64.deb"), selected)

    def test_selector_saved_actual_release_metadata(self):
        selected = self.select(json.loads((EVIDENCE / "metadata/fork-releases.json").read_text()))
        self.assertTrue(selected["package"].endswith("/opencode_2.0.19_aarch64.deb"), selected)

    def test_selector_missing_matching_asset(self):
        for names in [["opencode_1.18.27_aarch64.deb"], ["opencode_2.0.26_aarch64.deb"], ["opencode_2.0.27_x64.deb"], []]:
            with self.subTest(names=names):
                self.assertIsNone(self.select([release(names=names)]))

    def test_selector_invalid_tags_and_drafts(self):
        for tag in ["v1.18.27", "v2-2.0.27-android-rc1", "v2.00.27", "v2.0", "v2.0.27-alpha.01", "v2.0.27_foo"]:
            with self.subTest(tag=tag):
                version = tag.removeprefix("v").split("-android")[0]
                self.assertIsNone(self.select([release(tag, [f"opencode_{version}_aarch64.deb"])]))
        self.assertIsNone(self.select([release(draft=True)]))
        self.assertIsNone(self.select(None))

    def test_selector_preserves_release_order_and_prerelease(self):
        older = release("v2.0.26-android-rc9", ["opencode_2.0.26_aarch64.deb"])
        self.assertEqual(self.select([older, release()])["version"], "2.0.26")
        prerelease = release("v2.0.27-beta.1-android-rc1", ["opencode_2.0.27-beta.1_aarch64.deb"])
        self.assertEqual(self.select([prerelease])["version"], "2.0.27-beta.1")
        self.assertEqual(self.select([release(draft=True), release()])["version"], "2.0.27")

    def test_updater_invocation_and_existing_policy_preserved(self):
        patch = (REPO / "patches/opencode2/updater-android-channel.patch").read_text()
        self.assertIn('return yield* termuxRelease()', patch)
        self.assertIn('releases?per_page=10', patch)
        self.assertNotIn('dpkg', '\n'.join(l for l in patch.splitlines() if l.startswith('+') and not l.startswith('+    //')))
        self.assertNotIn('updater-action.ts', patch)

    def test_shared_action_keeps_equality_and_rollback_notifications(self):
        source = (EVIDENCE / "opencode/packages/cli/src/services/updater-action.ts").read_text()
        source = source[source.index("const maximumComponent"):]
        source = source.replace("export function", "function")
        source = source.replace("current: string, latest: string, policy: Policy): Action", "current, latest, policy)")
        source = source.replace("input: string", "input").replace("value: string", "value")
        source = source.replace("current: NonNullable<ReturnType<typeof parseReleaseVersion>>, latest: typeof current", "current, latest")
        source += '''
const assert=require("node:assert/strict");
assert.equal(action("2.0.27","2.0.27","notify"),"none");
assert.equal(action("2.0.27","2.0.26","notify"),"notify");
assert.equal(action("2.0.27","2.0.28","disable"),"none");
assert.equal(action("2.0.27","2.0.28","auto"),"auto");
assert.equal(action("2.0.27+old","2.0.27+new","notify"),"none");
'''
        result = run(["node", "-e", source])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_all_source_patches_forward_reverse(self):
        for tree, patches in [("opencode", sorted((REPO / "patches/opencode2").glob("*.patch"))),
                              ("opentui", [REPO / "patches/opentui/v2-0.5.12-android-termux.patch"])]:
            with self.subTest(tree=tree):
                target = scratch() / tree
                shutil.copytree(EVIDENCE / tree, target, ignore=shutil.ignore_patterns(".git"))
                self.assertEqual(run(["git", "init", "-q", str(target)]).returncode, 0)
                for patch in patches:
                    for flags in [["--check"], [], ["--check", "--reverse"]]:
                        result = run(["git", "-C", str(target), "apply", *flags, str(patch)])
                        self.assertEqual(result.returncode, 0, f"{patch.name} {flags}: {result.stderr}")

    def test_runtime_real_handlers_and_idempotency(self):
        root, destination = copy_runtime()
        before = {p.name: p.read_bytes() for p in destination.glob("*.js")}
        result = runtime_patch(root)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        after = {p.name: p.read_bytes() for p in destination.glob("*.js")}
        handlers = 0
        for name, data in before.items():
            if b"function getCurrentNodeAssetTarget()" not in data:
                self.assertEqual(after[name], data)
                continue
            handlers += 1
            check = run(["node", "-e", NODE_RUNTIME], input=json.dumps({"before": data.decode(), "after": after[name].decode()}))
            self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(handlers, 2)
        self.assertEqual(runtime_patch(root).returncode, 0)
        self.assertEqual(after, {p.name: p.read_bytes() for p in destination.glob("*.js")})

    def test_runtime_rejects_missing_either_anchor(self):
        for anchor in ['  return {\n    platform: process.platform,',
                       'async function resolveNativeLibraryPath() {\n  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());']:
            with self.subTest(anchor=anchor):
                root, destination = copy_runtime()
                handler = next(p for p in destination.glob("chunk-bun-*.js") if anchor in p.read_text())
                handler.write_text(handler.read_text().replace(anchor, anchor.replace('process.platform', 'process["platform"]').replace('const asset', 'const  asset'), 1))
                result = runtime_patch(root)
                self.assertNotEqual(result.returncode, 0, "accepted missing required anchor: " + result.stdout)

    def test_runtime_rejects_partial_already_patched(self):
        root, destination = copy_runtime()
        self.assertEqual(runtime_patch(root).returncode, 0)
        handler = next(p for p in destination.glob("chunk-bun-*.js") if 'async function resolveNativeLibraryPath()' in p.read_text())
        text = handler.read_text().replace('  if (process.env.OPENTUI_LIB_PATH) return process.env.OPENTUI_LIB_PATH;\n', '')
        # Damage the vanilla resolver anchor too: normalized platform alone must not count as already patched.
        handler.write_text(text.replace('  const asset = getNativeAssetDescriptor', '  const  asset = getNativeAssetDescriptor', 1))
        self.assertNotEqual(runtime_patch(root).returncode, 0)

    def test_runtime_rejects_ambiguous_or_missing_runtime_family(self):
        root, destination = copy_runtime()
        handler = next(p for p in destination.glob("chunk-bun-*.js") if 'function getCurrentNodeAssetTarget()' in p.read_text())
        handler.write_text(handler.read_text() + '\n  return {\n    platform: process.platform,\n')
        self.assertNotEqual(runtime_patch(root).returncode, 0)
        root, destination = copy_runtime()
        # Keep filenames but remove only the disposable fixture's Bun contents;
        # a valid Node handler must not conceal a missing Bun runtime family.
        for handler in destination.glob("chunk-bun-*.js"):
            handler.write_text("// Fixture without runtime functions.\n")
        self.assertNotEqual(runtime_patch(root).returncode, 0)

    def test_source_guard_and_placement(self):
        code = heredoc("V2_SOURCE_CHECK")
        script = (REPO / "scripts/build-opencode2.sh").read_text()
        self.assertLess(script.index("<<'V2_SOURCE_CHECK'"), script.index('GOT="'))
        self.assertLess(script.index("<<'V2_SOURCE_CHECK'"), script.index('"$HOST_BUN" install'))
        root = scratch()
        manifest = json.loads((EVIDENCE / "opencode/package.json").read_text())
        for version, renderer, expected in [("2.0.27", "0.5.17", 0), ("2.0.19", "0.5.17", 1), ("2.0.27", "0.5.12", 1)]:
            with self.subTest(version=version, renderer=renderer):
                (root / "package.json").write_text(json.dumps(manifest))
                result = run(["python3", "-", str(root), version, renderer], input=code)
                self.assertEqual(result.returncode, expected, result.stderr)
        for name in ["@opentui/core", "@opentui/solid", "@opentui/keymap"]:
            changed = json.loads(json.dumps(manifest))
            changed["workspaces"]["catalog"][name] = "0.5.12"
            (root / "package.json").write_text(json.dumps(changed))
            self.assertNotEqual(run(["python3", "-", str(root), "2.0.27", "0.5.17"], input=code).returncode, 0)

    def test_reused_source_mismatch_stops_actual_preinstall_prefix(self):
        script = (REPO / "scripts/build-opencode2.sh").read_text()
        # Run the actual source-selection/validation prefix only. The success
        # marker is where patch/install work would begin; nothing beyond it runs.
        prefix = script.split("# Add the Android target to the upstream build matrix", 1)[0]
        prefix = re.sub(r'^SCRIPT_DIR=.*$', 'SCRIPT_DIR=' + json.dumps(str(REPO / "scripts")), prefix, flags=re.M)
        root = scratch()
        self.assertEqual(run(["git", "init", "-q", str(root)]).returncode, 0)
        manifest = json.loads((EVIDENCE / "opencode/package.json").read_text())
        manifest["version"] = "2.0.19"
        (root / "package.json").write_text(json.dumps(manifest))
        marker = root / "would-patch-or-install"
        result = run(["bash", "-c", prefix + '\nprintf reached > "$TEST_MARKER"'],
                     env={**os.environ, "OPENCODE_V2_WORKTREE": str(root), "OPENCODE_V2_REF": "v2.0.27",
                          "OPENCODE_V2_PKGVER": "2.0.27", "OPENTUI_VERSION": "0.5.17", "TEST_MARKER": str(marker)})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("source version and OPENCODE_V2_PKGVER disagree", result.stderr)
        self.assertFalse(marker.exists())

    def test_env_pins(self):
        env = {k: v for k, v in os.environ.items() if k not in ["BUN_VERSION", "OPENTUI_VERSION", "OPENCODE_V2_REF", "OPENCODE_V2_PKGVER", "OPENCODE_CHANNEL", "ZIG_V2_VERSION", "ANDROID_API"]}
        result = run(["bash", "-c", 'source "$1" >/dev/null; printf "%s\\n" "$BUN_VERSION" "$OPENTUI_VERSION" "$OPENCODE_V2_REF" "$OPENCODE_V2_PKGVER" "$ZIG_V2_VERSION" "$ANDROID_API" "$OPENCODE_CHANNEL"', "test", str(REPO / "scripts/env-v2.sh")], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["1.4.2", "0.5.17", "v2.0.27", "2.0.27", "0.16.0", "24", "android-termux"])

    def test_workflow_version_input_and_release_tag(self):
        workflow = (REPO / ".github/workflows/build.yml").read_text()
        self.assertIn("default: 'v2.0.27'", workflow)
        job = workflow.split("  build-v2:", 1)[1]
        for pin in ['OPENTUI_VERSION: "0.5.17"', 'OPENCODE_V2_REF: "v2.0.27"', 'OPENCODE_V2_PKGVER: "2.0.27"']:
            self.assertIn(pin, job)
        block = job.split("      - name: Override OpenCode v2 ref from input\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("OPENCODE_V2_PKGVER=", block)
        self.assertIn('tag="v${OPENCODE_V2_PKGVER}-', job)
        code = block.split("        run: |\n", 1)[1]
        code = '\n'.join(line[10:] for line in code.splitlines())
        for ref, expected in [("v2.0.27", 0), ("v2.0.28-beta.1", 0), ("dev", 1), ("v1.19.0", 1), ("v2.0.27 bad", 1)]:
            with self.subTest(ref=ref):
                root = scratch()
                output = root / "github-env"
                result = run(["bash", "-c", code], env={**os.environ, "V2_REF_INPUT": ref, "GITHUB_ENV": str(output)})
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected == 0:
                    self.assertIn("OPENCODE_V2_REF=" + ref, output.read_text())
                    self.assertIn("OPENCODE_V2_PKGVER=" + ref[1:], output.read_text())

    def test_manual_install_docs(self):
        readme = (REPO / "README.md").read_text()
        default = readme.split("## Install (Termux)", 1)[1].split("### Legacy v1 line", 1)[0]
        self.assertIn('/releases/download/v2.0.27-android-rc1/opencode_2.0.27_aarch64.deb', default)
        self.assertNotIn('/releases/latest/', default)
        self.assertIn('--ref v2.0.27-android-rc1', default)
        self.assertIn('not the recommended path for this update', default)
        self.assertIn('historical/reference use only', default)
        self.assertEqual(default.count("curl -LO "), 2, "one deb plus optional installer, no all-format downloads")
        self.assertIn('OpenCode 2.0.27', readme[:readme.index("## Install")])

    def test_package_layout_and_build_contracts(self):
        package = (REPO / "scripts/make-packages-v2.sh").read_text()
        for token in ['DEB_NAME="opencode_${OPENCODE_V2_PKGVER}_aarch64.deb"', 'Package: opencode', 'Architecture: aarch64', 'libexec/opencode/libopentui.so', 'libexec/opencode/libtagfix.so', 'check_android_shared_object "$ARM64_LIBOPENTUI"', 'check_elf_aarch64 "$OPENCODE2_BINARY"']:
            self.assertIn(token, package)
        native = (REPO / "scripts/build-opentui-v2.sh").read_text()
        self.assertIn('patches/opentui/v2-0.5.12-android-termux.patch', native)
        self.assertIn('0.5.17', native)
        self.assertIn('-Dlibrary-target=aarch64-linux-android', native)
        script = (REPO / "scripts/build-opencode2.sh").read_text()
        self.assertIn('--skip-install', script)
        self.assertIn('export OPENCODE_VERSION="$OPENCODE_V2_PKGVER"', script)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--evidence-root", type=Path, required=True)
    args, extra = parser.parse_known_args()
    EVIDENCE = args.evidence_root.resolve()
    for required in ["opencode/package.json", "opencode/packages/cli/src/services/updater-action.ts", "opentui/packages/native/build.zig", "npm-core"]:
        if not (EVIDENCE / required).exists():
            parser.error(f"missing saved offline input: {required}; this test never downloads inputs")
    for tool in ["node", "git"]:
        if not shutil.which(tool):
            parser.error(f"{tool} required; this test never installs tools")
    unittest.main(argv=[__file__, *extra], verbosity=2)

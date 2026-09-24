#!/usr/bin/env python3
"""Mocked release gates and renamed paths; never build, sign, upload, or install."""
from pathlib import Path
import os
import base64
import plistlib
import shutil
import subprocess
import tempfile
from public_documents import document_paths

ROOT = Path(__file__).resolve().parent.parent


def mock(directory, name, body):
    path = directory / name
    path.write_text("#!/bin/bash\nset -eu\n" +
                    'printf \'%s %s\\n\' "${0##*/}" "$*" >> "$FIXTURE_CALL_LOG"\n' + body)
    path.chmod(0o755)


def main():
    with tempfile.TemporaryDirectory(prefix="expertise-package-fixtures-") as temporary:
        fixture = Path(temporary).resolve()
        (fixture / "scripts").mkdir()
        for name in ("make-dmg.sh", "public_documents.py", "configure-hosted-service.py", "release-preflight.sh", "release.sh", "test.sh", "verify-release-app.py"):
            shutil.copy2(ROOT / "scripts" / name, fixture / "scripts" / name)
        shutil.copy2(ROOT / "scripts/update-config.py", fixture / "scripts/update-config.py")
        version = (ROOT / "VERSION").read_text().strip()
        (fixture / "VERSION").write_text(version + "\n")
        documents = document_paths(ROOT)
        for source in documents:
            destination = fixture / source.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        (fixture / "docs/images").mkdir(exist_ok=True)
        (fixture / "docs/images/fixture.png").write_bytes(b"Synthetic packaging image fixture; not a real screenshot.")
        with (fixture / "MINT.md").open("a") as guide:
            guide.write("\n![Fixture illustration](docs/images/fixture.png)\n")
        mint = (fixture / "MINT.md").read_bytes()
        (fixture / "docs/evidence/fixture").mkdir(parents=True)
        # Historical reports can exist in an operator checkout but must not be
        # required or silently copied by the public documentation inventory.
        (fixture / "docs/release-1.1.8.md").write_text("Private historical fixture.\n")
        (fixture / "docs/evidence/fixture/reviewed.json").write_text("{}\n")
        (fixture / "docs/evidence/fixture/private.json").write_text("Not for distribution.\n")
        (fixture / "docs/distribution-evidence.txt").write_text("evidence/fixture/reviewed.json\n")
        (fixture / "Resources").mkdir(exist_ok=True)
        for name in ("Info.plist", "FnDictate.entitlements"):
            shutil.copy2(ROOT / "Resources" / name, fixture / "Resources" / name)
        app = fixture / "build/Expertise Dictation.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = version
        info["SUFeedURL"] = "https://updates.sparkle-project.org/appcast.xml"
        info["SUPublicEDKey"] = base64.b64encode(bytes([42]) * 32).decode()
        info["ExpertiseServiceURL"] = "https://dictation.example.com"
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        base = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
        for helper in ("Updater.app", "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc"):
            (base / helper).mkdir(parents=True)
        (base / "Autoupdate").write_text("fixture")
        executable = app / "Contents/MacOS/FnDictate"
        executable.write_text('#!/bin/bash\n[[ "$1" == --selftest ]] || exit 90\n')
        executable.chmod(0o755)
        mocks = fixture / "mocks"
        mocks.mkdir()
        mock(mocks, "security", '[[ "$FIXTURE_FAILURE" != identity ]] || exit 0\necho \'  1) 0123456789012345678901234567890123456789 "Developer ID Application: Fixture (FIXTURE123)"\'\n')
        mock(mocks, "codesign", '''for target; do :; done
[[ "$FIXTURE_FAILURE" != signature || "$*" != *"--verify"* ]] || exit 1
[[ "$FIXTURE_FAILURE" != dmg_signature || "$target" != *.dmg ]] || exit 1
if [[ "$*" == *"--entitlements"* ]]; then
extra=''
if [[ "$target" == *"/Expertise Dictation.app" ]]; then
extra='<key>com.apple.security.device.audio-input</key><true/>'
if [[ "$FIXTURE_FAILURE" == entitlements ]]; then extra="$extra<key>com.apple.security.cs.disable-library-validation</key><true/>"; fi
elif [[ "$FIXTURE_FAILURE" == helper_entitlements ]]; then
extra='<key>com.apple.security.get-task-allow</key><true/>'
fi
printf '<?xml version="1.0"?><plist version="1.0"><dict>%s</dict></plist>\\n' "$extra"
elif [[ "$*" == *"-dv"* ]]; then
team=FIXTURE123
runtime='flags=0x10000(runtime)'
authority='Developer ID Application: Fixture'
timestamp='Timestamp=Fixture'
[[ "$FIXTURE_FAILURE" != adhoc ]] || authority='Ad Hoc Fixture'
[[ "$FIXTURE_FAILURE" != timestamp ]] || timestamp=''
if [[ "$target" == *Installer.xpc && "$*" == *x86_64* ]]; then
[[ "$FIXTURE_FAILURE" != helper_team ]] || team=OTHERTEAM
[[ "$FIXTURE_FAILURE" != helper_runtime ]] || runtime='flags=0'
fi
printf 'Authority=%s (%s)\\nTeamIdentifier=%s\\n%s\\n%s\\n' "$authority" "$team" "$team" "$runtime" "$timestamp" >&2
fi
''')
        mock(mocks, "xcrun", '''if [[ "$1" == --find ]]; then echo /usr/bin/true; exit 0; fi
if [[ "$1" == notarytool ]]; then
case "$2" in
history) [[ "$FIXTURE_FAILURE" != credentials ]] || exit 1; echo '{"history": []}' ;;
submit)
status=Accepted
if [[ "$FIXTURE_FAILURE" == notary || ( "$FIXTURE_FAILURE" == dmg_notary && "$3" == *.dmg ) ]]; then status=Invalid; fi
[[ "$FIXTURE_FAILURE" != timeout ]] || exit 1
printf '{"id":"fixture-submission","status":"%s"}\\n' "$status"
;;
log) echo '{}' > "$4" ;;
esac
elif [[ "$1" == stapler ]]; then
[[ "$FIXTURE_FAILURE" != staple ]] || exit 1
[[ "$FIXTURE_FAILURE" != dmg_staple || "$3" != *.dmg ]] || exit 1
[[ "$FIXTURE_FAILURE" != staple_validate || "$2" != validate ]] || exit 1
fi
''')
        mock(mocks, "hdiutil", '''if [[ "$1" == create ]]; then
for last; do :; done
previous=''
for arg; do
if [[ "$previous" == -srcfolder ]]; then image="$arg"; fi
previous="$arg"
done
while IFS= read -r document; do
[[ -f "$image/$document" ]] || exit 9
done < "$FIXTURE_DOCUMENTS"
if [[ "$FIXTURE_EVIDENCE" == present ]]; then
[[ -f "$image/docs/evidence/fixture/reviewed.json" ]] || exit 9
else
[[ ! -e "$image/docs/evidence" ]] || exit 9
fi
[[ -d "$image/Expertise Dictation.app" && ! -e "$image/FnDictate.app" ]] || exit 10
[[ ! -e "$image/docs/evidence/fixture/private.json" ]] || exit 11
[[ ! -e "$image/docs/release-1.1.8.md" ]] || exit 12
python3 - "$image/Read me first.txt" <<'PY'
import pathlib, sys
note = pathlib.Path(sys.argv[1]).read_text()
assert "guided permissions" in note and "optional personal API-key connection" in note
assert "access and an API key" not in note
PY
if [[ "$FIXTURE_MODE" == --notarized ]]; then
python3 - "$image/Read me first.txt" <<'PY'
import pathlib, sys
assert "Automatic updates are unavailable" in pathlib.Path(sys.argv[1]).read_text()
PY
fi
printf 'Fixture image; not installable.\\n' > "$last"
fi
[[ "$FIXTURE_FAILURE" != image_verify || "$1" != verify ]] || exit 1
''')
        mock(mocks, "spctl", '''[[ "$FIXTURE_FAILURE" != gatekeeper ]] || exit 1
[[ "$FIXTURE_FAILURE" != dmg_gatekeeper || "$*" != *"--type open"* ]] || exit 1
''')
        mock(mocks, "lipo", 'echo "x86_64 arm64"\n')
        env = dict(os.environ, PATH=str(mocks) + ":" + os.environ["PATH"],
                   BUILD_DIR=str(fixture / "build"), SKIP_BUILD="1")
        env.pop("SIGN_IDENTITY", None)
        inventory = fixture / "documents.txt"
        inventory.write_text("\n".join(str(p.relative_to(fixture)) for p in document_paths(fixture)) + "\n")
        # Exercise the actual source export, not a second hand-written imitation.
        # It intentionally has no private historical docs or operator allowlist.
        exported = fixture / "public-source"
        subprocess.run(["python3", str(ROOT / "scripts/export-public-source.py"), str(exported)],
                       check=True, capture_output=True, text=True)
        assert not (exported / "docs/distribution-evidence.txt").exists()
        assert not (exported / "docs/release-1.1.8.md").exists()
        export_inventory = fixture / "export-documents.txt"
        export_inventory.write_text("\n".join(str(p.relative_to(exported)) for p in document_paths(exported)) + "\n")
        cases = [("release_" + failure, "--release", failure, "missing" if failure == "update_config" else "configured")
                 for failure in ("update_config", "entitlements", "helper_team", "helper_runtime", "helper_entitlements", "notary", "staple", "gatekeeper", "none")]
        cases += [("local", "--local", "none", "missing")]
        cases += [("manual_" + failure, "--notarized", failure, "missing")
                  for failure in ("none", "identity", "credentials", "signature", "adhoc", "timestamp",
                                  "entitlements", "helper_team", "helper_runtime", "helper_entitlements",
                                  "notary", "timeout", "staple", "staple_validate", "gatekeeper",
                                  "dmg_signature", "dmg_notary", "dmg_staple", "dmg_gatekeeper", "image_verify")]
        cases += [("manual_config_" + configuration, "--notarized", "none", configuration)
                  for configuration in ("configured", "feed_only", "key_only", "invalid", "empty", "unsigned_feed")]
        cases += [("public_source", "--local", "none", "missing"),
                  ("without_operator_evidence", "--local", "none", "missing")]
        cases += [(case, "--local", "documentation", "missing") for case in (
            "missing_current_guide", "broken_local_link", "missing_linked_image", "symlink_document",
            "unsafe_evidence", "missing_evidence", "symlink_evidence")]
        # These use a reserved example domain syntactically only; no HTTP request
        # is made, and no deployment/readiness claim follows from a passing check.
        hosted_cases = {
            "hosted_skip_missing": ("--release", None, version, "release.sh", False),
            "hosted_manual_missing": ("--notarized", None, version, "release.sh", False),
            "hosted_http": ("--release", "http://dictation.example.com", version, "release.sh", False),
            "hosted_credentials": ("--release", "https://user:fixture@dictation.example.com", version, "release.sh", False),
            "hosted_localhost": ("--release", "https://test.localhost", version, "release.sh", False),
            "hosted_ip": ("--release", "https://127.0.0.1", version, "release.sh", False),
            "hosted_bad_hostname": ("--release", "https://bad_host.example.com", version, "release.sh", False),
            "hosted_query": ("--release", "https://dictation.example.com?fixture=1", version, "release.sh", False),
            "hosted_direct_missing": ("--release", None, version, "make-dmg.sh", False),
            "hosted_direct_unsafe": ("--notarized", "https://dictation.example.com/path", version, "make-dmg.sh", False),
            "hosted_direct_present": ("--release", "https://dictation.example.com:443/", version, "make-dmg.sh", True),
            "hosted_legacy_missing": ("--release", None, "1.1.8", "release.sh", True),
            "hosted_future_missing": ("--release", None, "1.2.0", "release.sh", False),
            "public_source_release": ("--release", "https://dictation.example.com", version, "release.sh", True),
        }
        cases += [(name, mode, "none" if succeeds else "hosted", "missing" if mode == "--notarized" else "configured")
                  for name, (mode, _, _, _, succeeds) in hosted_cases.items()]
        for case, mode, failure, configuration in cases:
            changed = None
            evidence = fixture / "docs/distribution-evidence.txt"
            if case == "without_operator_evidence":
                evidence.unlink()
            elif case == "missing_current_guide":
                changed = fixture / "docs/release-1.1.9.md"
                original = changed.read_bytes()
                changed.unlink()
            elif case == "broken_local_link":
                with (fixture / "MINT.md").open("a") as guide:
                    guide.write("\n[Missing documentation](docs/not-included.md)\n")
            elif case == "missing_linked_image":
                with (fixture / "MINT.md").open("a") as guide:
                    guide.write("\n![Missing screenshot](docs/images/missing.png)\n")
            elif case == "symlink_document":
                changed = fixture / "docs/release-1.1.9.md"
                original = changed.read_bytes()
                changed.unlink()
                changed.symlink_to(fixture / "docs/release-1.1.8.md")
            elif case == "unsafe_evidence":
                evidence.write_text("evidence/../release-1.1.8.md\n")
            elif case == "missing_evidence":
                evidence.write_text("evidence/fixture/absent.json\n")
            elif case == "symlink_evidence":
                (fixture / "docs/evidence/fixture/linked.json").symlink_to("private.json")
                evidence.write_text("evidence/fixture/linked.json\n")
            current_info = dict(info)
            case_version = hosted_cases[case][2] if case in hosted_cases else version
            current_info["CFBundleShortVersionString"] = case_version
            current_info["CFBundleVersion"] = case_version
            service_url = hosted_cases[case][1] if case in hosted_cases else info["ExpertiseServiceURL"]
            if service_url is None or mode == "--local":
                current_info.pop("ExpertiseServiceURL", None)
            else:
                current_info["ExpertiseServiceURL"] = service_url
            if configuration in ("missing", "unsigned_feed"):
                current_info.pop("SUFeedURL")
                current_info.pop("SUPublicEDKey")
            elif configuration == "feed_only":
                current_info.pop("SUPublicEDKey")
            elif configuration == "key_only":
                current_info.pop("SUFeedURL")
            elif configuration == "invalid":
                current_info["SUFeedURL"] = "http://localhost/appcast.xml"
            elif configuration == "empty":
                current_info["SUFeedURL"] = ""
                current_info["SUPublicEDKey"] = ""
            if configuration == "unsigned_feed":
                current_info["SURequireSignedFeed"] = False
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(current_info))
            target = fixture / ("out-" + case)
            call_log = fixture / (case + ".calls")
            public_source = case in ("public_source", "public_source_release")
            runenv = dict(env, DIST_DIR=str(target), FIXTURE_FAILURE=failure,
                          FIXTURE_MODE=mode, FIXTURE_CALL_LOG=str(call_log),
                          FIXTURE_DOCUMENTS=str(export_inventory if public_source else inventory),
                          FIXTURE_EVIDENCE="absent" if public_source or case == "without_operator_evidence" else "present",
                          VERSION=case_version, HOSTED_SERVICE_REQUIRED="0",
                          EXPERTISE_SERVICE_URL="https://environment-cannot-repair-built-app.example.com")
            source_root = exported if public_source else fixture
            entrypoint = hosted_cases[case][3] if case in hosted_cases else "release.sh"
            original_plist = (app / "Contents/Info.plist").read_bytes()
            run = subprocess.run([str(source_root / "scripts" / entrypoint), mode], cwd=source_root,
                                 env=runenv, capture_output=True, text=True)
            assert (app / "Contents/Info.plist").read_bytes() == original_plist, (case, "release checks modified the signed plist")
            finals = list(target.glob("*.dmg"))
            calls = call_log.read_text().splitlines() if call_log.exists() else []
            succeeds = failure == "none" and not case.startswith("manual_config_")
            if succeeds:
                suffix = {"--local": "-local", "--notarized": "-notarized-manual", "--release": ""}[mode]
                name = "Expertise-Dictation-" + case_version + suffix
                assert run.returncode == 0 and [p.name for p in finals] == [name + ".dmg"], (case, run.stdout, run.stderr)
                assert Path(str(finals[0]) + ".sha256").exists()
                receipt = (target / (name + "-release.txt")).read_text()
                assert receipt.startswith("Expertise Dictation " + case_version)
                assert "docs/rewrite-design.md" in receipt and "docs/release-1.1.9.md" in receipt
                assert "README.md" in receipt and "LICENSE" in receipt and "THIRD_PARTY_NOTICES.md" in receipt
                assert "docs/release-1.1.8.md" not in receipt
                for document in Path(runenv["FIXTURE_DOCUMENTS"]).read_text().splitlines():
                    assert document in receipt, (case, document)
                if mode == "--local":
                    assert "NOT Apple notarized" in receipt
                    assert not any("notarytool submit " in call for call in calls)
                else:
                    assert "App notarization: fixture-submission" in receipt
                    assert "DMG notarization: fixture-submission" in receipt
                    for operation in ("xcrun notarytool submit ", "xcrun stapler staple ", "xcrun stapler validate ", "spctl --assess "):
                        assert sum(call.startswith(operation) for call in calls) == 2, (case, operation, calls)
                if mode == "--notarized":
                    assert "manual installation; automatic updates unavailable" in receipt
                before = finals[0].read_bytes()
                again = subprocess.run([str(source_root / "scripts" / entrypoint), mode], cwd=source_root,
                                       env=runenv, capture_output=True, text=True)
                assert again.returncode != 0 and finals[0].read_bytes() == before
                print("PASS mocked packaging:", case, "all required gates, reviewed inventory, existing output preserved")
            else:
                assert run.returncode != 0 and not finals, (case, run.stdout, run.stderr)
                assert not list(target.glob("*.dmg.sha256")) and not list(target.glob("*-release.txt"))
                if case.startswith("manual_config_") or failure in ("update_config", "hosted"):
                    assert not any("notarytool submit " in call for call in calls), (case, calls)
                if failure == "hosted":
                    assert not any(call.startswith("hdiutil create ") for call in calls)
                    assert "service" in run.stderr.lower(), (case, run.stderr)
                print("PASS mocked packaging:", case, "cannot produce a final artifact or receipt")
            assert not list(target.glob(".expertise-dictation-package.*"))
            assert not list(target.glob(".*.package-lock"))
            if changed is not None:
                changed.unlink(missing_ok=True)
                changed.write_bytes(original)
            (fixture / "MINT.md").write_bytes(mint)
            evidence.write_text("evidence/fixture/reviewed.json\n")
        # Prove the environment is checked before a real build could begin.
        # The stub records that boundary and exits; it does not compile anything.
        build_stub = fixture / "scripts/build.sh"
        build_stub.write_text('#!/bin/bash\nprintf "fixture-build\\n" >> "$FIXTURE_CALL_LOG"\nexit 79\n')
        build_stub.chmod(0o755)
        for case, mode, requested_version, service_url, reaches_build in (
            ("hosted_prebuild_missing", "--release", version, "", False),
            ("hosted_prebuild_unsafe", "--notarized", version, "http://dictation.example.com", False),
            ("hosted_prebuild_present", "--release", version, "https://dictation.example.com", True),
            ("hosted_prebuild_legacy", "--release", "1.1.8", "", True),
            ("hosted_prebuild_local", "--local", version, "", True),
        ):
            call_log = fixture / (case + ".calls")
            runenv = dict(env, SKIP_BUILD="0", VERSION=requested_version, FIXTURE_FAILURE="none",
                          FIXTURE_CALL_LOG=str(call_log), EXPERTISE_SERVICE_URL=service_url,
                          HOSTED_SERVICE_REQUIRED="0", DIST_DIR=str(fixture / ("out-" + case)))
            run = subprocess.run([str(fixture / "scripts/release.sh"), mode], cwd=fixture,
                                 env=runenv, capture_output=True, text=True)
            calls = call_log.read_text().splitlines() if call_log.exists() else []
            assert ("fixture-build" in calls) == reaches_build, (case, calls, run.stderr)
            assert run.returncode == 79 if reaches_build else run.returncode != 0
            assert not any("notarytool submit " in call for call in calls)
            print("PASS mocked packaging:", case, "validated before build; no real build or upload")
    print("All packaging fixtures passed. No real build, signing, notarization, or installation occurred.")


if __name__ == "__main__":
    main()

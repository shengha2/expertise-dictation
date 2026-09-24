#!/usr/bin/env python3
"""Check an actual --cleanup-file report against a synthetic fixture reference.

This validates the recorded result and completeness; it does not fabricate a
provider response or establish microphone hardware coverage.
"""
import argparse
import difflib
import hashlib
import json
import re
import sys
import unicodedata
from pathlib import Path


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).casefold() if c.isalnum())


def tokens(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?|[\u3400-\u9fff]", unicodedata.normalize('NFKC', text).casefold())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    failures = []
    try:
        manifest = json.loads(args.manifest.read_text())
        report = json.loads(args.report.read_text())
        reference_file = args.manifest.resolve().parent / manifest['referenceFile']
        reference = reference_file.read_text()
        if hashlib.sha256(reference_file.read_bytes()).hexdigest() != manifest['sha256']['reference']:
            failures.append('Reference SHA-256 differs from fixture manifest')
        if report.get('source') != 'text_file' or report.get('success') is not True:
            failures.append('Cleanup CLI did not report successful text-file processing')
        if report.get('fallbackCount') != 0 or report.get('error') not in (None, ''):
            failures.append('Cleanup used fallback or reported an error')
        if Path(report.get('inputFile', '')).resolve() != reference_file:
            failures.append('Input path differs from fixture reference')
        if report.get('inputText') != reference:
            failures.append('The complete reference was not provided as cleanup input')
        chunk_sizes = report.get('chunkInputCharacters', [])
        if (not chunk_sizes or report.get('chunkCount') != len(chunk_sizes)
                or max(chunk_sizes) > 1800 or sum(chunk_sizes) != report.get('inputCharacters')):
            failures.append('Cleanup chunk accounting is incomplete or exceeds the request limit')
        output = report.get('outputText', '')
        flat = normalized(output)
        cursor = 0
        anchors = []
        for anchor in manifest['anchors']:
            position = flat.find(normalized(anchor['text']), cursor)
            anchors.append({'text': anchor['text'], 'kind': anchor['kind'], 'matchedInOrder': position >= 0})
            if position < 0:
                failures.append('Missing or out-of-order anchor: ' + anchor['text'])
            else:
                cursor = position + len(normalized(anchor['text']))
        reference_tokens = tokens(reference)
        matcher = difflib.SequenceMatcher(None, reference_tokens, tokens(output), autojunk=False)
        coverage = sum(block.size for block in matcher.get_matching_blocks()) / max(1, len(reference_tokens))
        if coverage < .95:
            failures.append(f'Ordered reference-token coverage {coverage:.1%} is below 95%')
        result = {'success': not failures, 'evidenceType': 'synthetic_reference_real_cleanup_report',
                  'fixture': manifest['fixture'], 'reportFile': str(args.report.resolve()),
                  'model': report.get('model'), 'chunkCount': report.get('chunkCount'),
                  'fallbackCount': report.get('fallbackCount'), 'elapsedSeconds': report.get('elapsedSeconds'),
                  'orderedReferenceTokenCoverage': round(coverage, 5), 'anchors': anchors, 'failures': failures}
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        result = {'success': False, 'failures': ['Invalid evidence: ' + str(error)]}
    if args.output:
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    sys.exit(main())

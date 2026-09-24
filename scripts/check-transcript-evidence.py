#!/usr/bin/env python3
"""Validate an actual --transcribe --report JSON against a synthetic WAV fixture.

This tool never calls mock STT, invents a transcript, or converts a log into a
successful result. It checks provided run metadata and content; a local JSON file
cannot cryptographically establish that a provider request really occurred.
"""
import argparse
import difflib
import hashlib
import json
import math
import re
import sys
import unicodedata
import wave
from pathlib import Path


def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda:source.read(1048576),b''): digest.update(chunk)
    return digest.hexdigest()


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKC',text).casefold() if c.isalnum())


def tokens(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?|[\u3400-\u9fff]",unicodedata.normalize('NFKC',text).casefold())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest',type=Path)
    parser.add_argument('report',type=Path,help='Actual CLI --report JSON, not text copied into a fabricated report')
    parser.add_argument('--require-realtime',action='store_true')
    parser.add_argument('--require-mandarin',action='store_true')
    parser.add_argument('--minimum-reference-coverage',type=float,default=.85)
    parser.add_argument('--output',type=Path,help='Write machine-readable validation result')
    args=parser.parse_args()
    if not 0 <= args.minimum_reference_coverage <= 1: parser.error('coverage must be between zero and one')
    failures=[]
    try:
        manifest=json.loads(args.manifest.read_text())
        report=json.loads(args.report.read_text())
        base=args.manifest.resolve().parent
        audio=base/manifest['audioFile']; reference_file=base/manifest['referenceFile']
        if sha(audio)!=manifest['sha256']['audio']: failures.append('Audio SHA-256 differs from fixture manifest')
        if sha(reference_file)!=manifest['sha256']['reference']: failures.append('Reference SHA-256 differs from fixture manifest')
        with wave.open(str(audio),'rb') as wav:
            duration=wav.getnframes()/wav.getframerate()
            if (wav.getnchannels(),wav.getsampwidth(),wav.getframerate()) != (1,2,24000):
                failures.append('Fixture must be mono PCM16 at 24 kHz')
        if abs(duration-float(manifest['durationSeconds']))>.001:
            failures.append('Actual WAV duration differs from fixture manifest')
        if manifest.get('source')!='synthetic_offline_tts' or not manifest.get('notMicrophoneHardwareEvidence'):
            failures.append('Fixture source is not explicitly identified as synthetic offline TTS')
        if report.get('success') is not True: failures.append('Actual CLI run did not report success')
        if report.get('error') not in (None,''): failures.append('Actual CLI run contains an error')
        if report.get('source')!='audio_file': failures.append('Run source is not audio_file')
        engine=report.get('engine','')
        if not isinstance(engine,str) or not engine or re.search(r'mock|fake|fixture|simulate',engine,re.I):
            failures.append('Provider engine is missing or indicates simulated STT')
        input_file=report.get('inputFile','')
        if not input_file or Path(input_file).expanduser().resolve()!=audio.resolve():
            failures.append('Run inputFile does not match the fixture WAV')
        reported_duration=float(report.get('audioDurationSeconds',-1))
        captured=float(report.get('capturedAudioSeconds',-1))
        elapsed=float(report.get('elapsedSeconds',-1))
        if not all(math.isfinite(value) for value in (reported_duration,captured,elapsed)):
            failures.append('Run timing metadata must contain finite numbers')
        if abs(reported_duration-duration)>.5: failures.append('Run audio duration does not match the complete fixture')
        if captured<duration-.5 or captured>duration+.5:
            failures.append('Run did not capture the entire fixture duration')
        if elapsed<=0: failures.append('Run elapsedSeconds is missing or invalid')
        if args.require_realtime:
            if report.get('realTime') is not True: failures.append('Run was not requested in real-time mode')
            if elapsed<duration*.95: failures.append('Elapsed time is too short for a real-time audio run')
        attempts=report.get('attempts')
        if not isinstance(attempts,list) or not attempts or attempts[-1].get('success') is not True:
            failures.append('Run has no final successful provider attempt')
        transcript=report.get('transcript','')
        if not isinstance(transcript,str) or not transcript.strip():
            failures.append('Actual transcript is empty'); transcript=''
        flat=normalized(transcript)
        cursor=0; anchor_results=[]; checkpoint_matches=0; mandarin_matches=0
        for anchor in manifest['anchors']:
            optional=anchor.get('required',True) is False and not args.require_mandarin
            position=flat.find(normalized(anchor['text']),cursor)
            matched=position>=0
            anchor_results.append({'kind':anchor['kind'],'number':anchor.get('number'),'text':anchor['text'],
                                   'required':not optional,'matchedInOrder':matched,'position':position})
            if matched:
                cursor=position+len(normalized(anchor['text']))
                if anchor['kind']=='checkpoint': checkpoint_matches+=1
                if anchor['kind']=='mandarin': mandarin_matches+=1
            elif not optional:
                failures.append('Missing or out-of-order '+anchor['kind']+' anchor: '+anchor['text'])
        expected_count=int(manifest['checkpointCount'])
        if checkpoint_matches!=expected_count:
            failures.append(f'Only {checkpoint_matches} of {expected_count} minute checkpoints were found in order')
        reference_tokens=tokens(reference_file.read_text()); transcript_tokens=tokens(transcript)
        matcher=difflib.SequenceMatcher(None,reference_tokens,transcript_tokens,autojunk=False)
        matched_words=sum(block.size for block in matcher.get_matching_blocks())
        coverage=matched_words/max(1,len(reference_tokens))
        if coverage<args.minimum_reference_coverage:
            failures.append(f'Ordered reference-token coverage {coverage:.1%} is below {args.minimum_reference_coverage:.1%}')
        result={'success':not failures,'fixture':manifest['fixture'],'inputFile':str(audio),'reportFile':str(args.report.resolve()),
                'evidenceType':'synthetic_audio_real_provider_report','microphoneHardwareTest':False,
                'providerEngine':engine,'audioDurationSeconds':duration,'capturedAudioSeconds':captured,
                'elapsedSeconds':elapsed,'realTime':report.get('realTime'),
                'faultInjected':report.get('faultInjected'),'checkpointMatches':checkpoint_matches,
                'checkpointExpected':expected_count,'mandarinMatches':mandarin_matches,
                'orderedReferenceTokenCoverage':round(coverage,5),'anchors':anchor_results,'failures':failures}
    except (OSError,ValueError,KeyError,TypeError,AttributeError,wave.Error) as error:
        result={'success':False,'failures':['Invalid or incomplete evidence: '+str(error)],'microphoneHardwareTest':False}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result['success'] else 1

if __name__=='__main__': sys.exit(main())

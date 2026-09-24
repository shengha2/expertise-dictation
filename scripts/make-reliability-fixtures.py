#!/usr/bin/env python3
"""Build real offline TTS WAVs; never generate a fake transcription result.

Text and minute boundaries are deterministic. macOS voice rendering is cached by
text/voice/rate, and final WAVs contain only canonical PCM headers and samples.
Outputs are synthetic provider-test inputs, not microphone hardware evidence.
The legacy-named continuous-seven-minute fixture is a paced monologue with
minute-end pauses (up to 15 seconds), not uninterrupted speech. Use
continuous-boundary-125s to stress voiced audio crossing 60-second hard cuts.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import wave
from pathlib import Path

RATE = 24000
ROOT = Path(__file__).resolve().parents[1]
PAIRS = ['amber river','cedar lantern','silver meadow','coral window','maple compass',
         'velvet harbor','copper orchard','crystal garden','violet bridge','golden basket',
         'quiet mountain','scarlet feather','winter fountain','ivory staircase','distant lighthouse',
         'paper rainbow','olive bookshelf','ruby island','gentle thunder','willow courtyard',
         'cobalt doorway','sunrise valley','jasmine rooftop','hazel stream','marble station',
         'open horizon','mossy telescope','autumn mailbox','lemon kitchen','final summit']
NUMBERS = ['one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve',
           'thirteen','fourteen','fifteen','sixteen','seventeen','eighteen','nineteen','twenty',
           'twenty one','twenty two','twenty three','twenty four','twenty five','twenty six',
           'twenty seven','twenty eight','twenty nine','thirty']
PARAGRAPHS = '''We began the morning by opening the curtains and checking the weather before our planning meeting. A notebook on the kitchen table held three questions about the coming week. The first concerned a customer visit, the second covered a delayed delivery, and the third asked who would prepare the presentation. Instead of answering everything immediately, we decided to identify the decisions that actually needed attention today. That gave the conversation a clear starting point and left room for people to describe what had changed since Friday. I made fresh coffee while everyone opened the shared notes and settled into their seats.

The neighborhood library was preparing a weekend reading event for families. Volunteers moved the smaller chairs into a circle and placed picture books on a low shelf near the entrance. Outside, a gentle breeze carried the sound of traffic from the next street. The librarian explained that registration would remain open until Thursday evening, but nobody needed to reserve a place just to browse the collection. We offered to print a simple map showing the nearest bus stops. Clear directions would help visitors who had never been inside the building and would reduce confusion at the front desk during the busiest hour.

During the garden visit, the caretaker showed us how the watering schedule changed with the season. Young plants needed careful attention, while established shrubs could tolerate a few dry days. She recommended checking the soil with a finger before reaching for the hose. We walked past tomatoes, beans, and several rows of bright flowers that attracted bees. A narrow path led to a shaded bench where school groups could sit for short lessons. The most useful advice was to make one small observation each day. Written notes about sunlight and moisture could explain problems that otherwise seemed to appear without warning.

Our team reviewed a prototype for a simple appointment booking page. The main concern was whether someone using a phone could finish the form without zooming in or losing their place. We tried the page with larger text and an unfamiliar date format. One button appeared too close to the edge, and the confirmation message disappeared before everyone had time to read it. We wrote down those observations without debating the colors. After the basic interaction worked reliably, there would be plenty of time to refine the appearance. A short usability session had revealed more than another hour of looking at static screenshots.

The train journey gave me time to organize the notes from yesterday's interviews. Each conversation contained a useful detail about how people actually handled their daily work. One person copied information between two windows, while another kept a paper checklist beside the keyboard. Neither habit was visible in the official process diagram. I grouped the notes by task rather than by job title so that common frustrations would be easier to recognize. Before arriving at the station, I marked the questions that required a follow up. The goal was to understand the routine before proposing a new tool to change it.

At the community kitchen, the coordinator divided the preparation work into several manageable stages. Vegetables needed washing before anyone started chopping, and the large pot had to reach a steady simmer before the beans were added. We checked the ingredient labels because a few guests had food preferences listed on the attendance sheet. Someone suggested putting a separate spoon beside every serving bowl to keep the line moving. By lunchtime, the room smelled of fresh bread and roasted peppers. The meal was simple, but careful preparation made it possible to serve everyone without making the volunteers feel rushed or overwhelmed.

I spent part of the afternoon sorting photographs from a recent hiking trip. The best image was not the dramatic view from the summit but a quiet scene beside a stream. Sunlight reached the water through a gap in the trees, and a fallen branch formed a natural frame around the rocks. I kept a copy of the original before making any adjustments. Small changes to brightness helped reveal the details without changing the mood of the scene. When the folder was organized, I sent the group a selection rather than every picture. That made the shared collection easier to enjoy.

The workshop began with an ordinary bicycle placed upside down on a padded stand. Our instructor demonstrated how to inspect the tires, check the chain, and make sure both brakes responded smoothly. She emphasized that a quick check before each ride could catch a small problem while it was still easy to fix. We practiced removing a wheel and putting it back without rushing. Several people asked the same question about the direction of the tire pattern, which led to a useful demonstration. By the end of the session, a task that had seemed complicated felt much more approachable to everyone.

A small bookstore on the corner had invited a local illustrator to talk about making a children's book. She brought rough sketches, color studies, and a finished copy so we could see the progression. Some early drawings looked very different from the published pages, especially the expressions on the main character's face. The illustrator explained that reading the story aloud helped her decide where a picture needed more space. Questions from the audience focused on materials and daily routines. Her answer was practical: keep supplies easy to reach, draw regularly, and allow enough time to revise ideas that initially seem complete.

We tested the new meeting room equipment before the first guests arrived. The camera needed to show everyone at the table, and the microphone had to pick up a person speaking quietly near the window. A screen sharing cable was missing from the storage drawer, so we found a spare and labeled it clearly. After adjusting the lighting, we made a short recording and played it back. That simple check revealed an echo from the empty hallway. Closing the door solved the problem. A few minutes of preparation prevented the first ten minutes of the actual meeting from becoming a technical interruption.

The museum visit started in a gallery devoted to everyday objects from earlier generations. A collection of cooking utensils stood beside a display of handwritten letters and old travel tickets. The guide asked us to imagine which objects from our own homes might tell a useful story in the future. Different people chose different things: a favorite mug, a worn backpack, or a notebook filled with family recipes. The discussion made the exhibits feel less distant. Instead of memorizing dates, we considered how people solved ordinary problems with the materials available to them. That perspective stayed with me throughout the rest of the visit.

Before redesigning the volunteer schedule, we asked everyone which shifts were hardest to cover. Early mornings created problems for people who depended on public transportation, while late afternoons conflicted with school pickup. We put the responses on a simple calendar and looked for patterns. The solution was not to ask a few reliable people to do more. It was to divide several long shifts into shorter blocks and make the handoff instructions clearer. We agreed to try the arrangement for two weeks. After that, the volunteers would tell us what worked and which details still needed to change before the next event.

The rainy afternoon seemed like a good opportunity to repair the loose handle on a desk drawer. I cleared the surface, found the correct screwdriver, and placed the small screws in a bowl so they would not disappear. The wood around one hole had worn down, which explained why tightening the screw never lasted. A careful repair took longer than the temporary fixes I had tried before, but the handle finally stayed in place. While the tools were out, I checked the other drawers as well. Finishing several small repairs made the room feel noticeably easier to use the following morning.

Our conversation about the website began with a question about the people who visited it. Some wanted detailed information, while others simply needed a phone number and the opening hours. We watched how quickly each group could find what they needed. The most important details were buried below a large decorative image, so we moved them closer to the top. Longer explanations remained available on separate pages. We also checked whether the links made sense when read without the surrounding paragraph. By focusing on a few real tasks, the team reached useful decisions without having to agree on everyone's personal design preferences.

A friend described the process of moving into a smaller apartment near the city center. The difficult part was not packing boxes but deciding which things deserved a place in the new space. She measured the rooms before choosing furniture and set aside a day to sort documents. Items used every week received priority over things kept only out of habit. After the move, she discovered that a small reading corner mattered more than a large dining table. We discussed how a clear daily routine can guide practical decisions. The apartment worked well because its arrangement reflected how she actually spent her time.

The afternoon class focused on listening carefully before responding to a difficult question. We practiced summarizing what another person had said without adding advice or guessing their intentions. At first the exercise felt slow, especially when the answer seemed obvious. But several misunderstandings became clear once we repeated the question in our own words. The instructor suggested leaving a brief pause before offering a solution. That pause gave the speaker a chance to correct a detail or add missing context. By the final exercise, the group had become more comfortable asking for clarification instead of rushing toward an answer that might solve the wrong problem.

On the way to the market, we stopped at a small park where workers were replacing a damaged sign. The old map showed a path that had been closed for months, leaving visitors confused near the playground. The replacement included clear directions to the accessible entrance and the nearest drinking fountain. We watched as the workers checked the height of the sign before securing it to the post. A parent walking past pointed out that the morning sun could make the surface difficult to read. Moving the sign slightly into the shade was a small adjustment with a useful effect throughout the day.

The cooking lesson used a basic soup to explain how different ingredients build flavor over time. We started with onions and allowed them to soften before adding the other vegetables. The instructor asked us to taste the broth at several stages and describe what had changed. A squeeze of lemon at the end made a surprising difference, even though the amount was small. We wrote down the sequence rather than trying to remember a long list of exact measurements. Understanding why each step mattered made the recipe easier to adapt. Everyone left with a container of soup and a plan to try again at home.

A short walk along the waterfront helped us think through the proposal we had been discussing all morning. Away from the meeting room, it became easier to separate the essential work from the optional additions. We agreed that the first version needed to solve one common problem reliably. Extra settings would be useful only if people actually asked for them after trying the basic workflow. I recorded the decisions in a notebook when we stopped near a bench. Back at the office, we turned those notes into a small list of changes that could be reviewed together before the next round of testing.

The neighborhood cleanup brought together people who rarely had a reason to speak to one another. Some collected litter along the main path, while others sorted materials for recycling near the entrance. A local shop provided gloves and several large containers of drinking water. We found that clear labels on the collection bags prevented confusion later in the morning. Children helped count the filled bags and suggested places that needed attention next time. Before leaving, we took a photograph of the group beside the newly cleared garden bed. The visible result made it easier to imagine returning for another short session the following month.

We reviewed the instructions for a new piece of office equipment by asking someone unfamiliar with it to complete a basic task. The first step was clear, but the second referred to a button using a name that did not appear on the device. That mismatch forced the person to stop and guess. We revised the wording and added a small illustration showing the correct control. The next attempt went smoothly. The exercise reminded us that instructions should describe what a person can actually see. Internal terminology may be convenient for the team, but it creates unnecessary work for everyone encountering the product for the first time.

At the music rehearsal, the director asked each section to play a difficult passage slowly before returning to the full tempo. The problem was not the notes themselves but the timing of the transition into the next phrase. Hearing the sections separately made the source of the confusion obvious. We marked the change in our copies and practiced it several times with a steady count. When the whole group played together again, the music felt much more settled. Nobody needed a complicated explanation. A specific observation and a short, focused exercise had accomplished more than repeating the entire piece from beginning to end.

The school garden project began with a drawing made by the students. Their plan included vegetables, flowers, and a small place to sit during outdoor lessons. We compared the drawing with the available space and talked about which parts could be completed this season. The students chose a few plants that would grow quickly enough for them to observe changes before the holiday. They also made a schedule for watering during the week. Giving everyone a clear responsibility helped turn an ambitious idea into a manageable activity. The first afternoon ended with muddy shoes, careful labels, and a row of newly planted seeds.

I used a quiet evening to organize a folder of important household information. Receipts, equipment manuals, and contact details had collected in several different places, making simple questions harder to answer than they needed to be. I grouped related documents and gave each file a name that would still make sense months later. For paper items, a small set of labeled envelopes was enough. The goal was not to build an elaborate system but to make the next search faster. Before finishing, I wrote a brief index explaining where everything belonged so that another person could use the arrangement without asking for help.

The project review focused on the difference between completing a task and confirming that it worked. A button could appear on the page even if clicking it did nothing useful. A file could be created even if another person could not open it. We listed the observable result expected from each important action and tested those results directly. Where the outcome depended on an external service, we recorded that limitation instead of calling the feature finished. This approach made the review more concrete. The team could discuss evidence and remaining gaps rather than relying on a general impression that the project was almost ready.

During a visit to a local farm, we learned how the growers planned deliveries around the weekly harvest. Weather could change the schedule, so the packing list had to remain flexible until the produce was ready. Each box included a note explaining what was inside and how to store it. The farmer said that useful communication mattered as much as accurate counting. A customer who understood the reason for a substitution was less likely to be disappointed. We helped carry a few empty crates back to the shed and watched the next group of volunteers prepare the tables for an afternoon of sorting vegetables.

The discussion about travel plans became easier once we separated fixed commitments from preferences. The date of the conference could not change, but the route and the length of the stay were flexible. We compared the arrival times and allowed extra space for delays between connections. A hotel near the venue cost slightly more but reduced the amount of travel needed each morning. We wrote down the reasons for the choice so that someone joining the trip later would understand the plan. The result was a practical itinerary with enough room to handle ordinary surprises without turning every small change into a problem.

A group of neighbors met to plan a small outdoor film screening. We checked where the screen could stand without blocking the walking path and where the electrical cable could run safely. The sound needed to reach the audience without disturbing nearby homes. Someone suggested testing the setup at the same time of day as the event, because changing light would affect the picture. We also prepared an indoor alternative in case of rain. By the end of the meeting, each person had one clear task and a way to report progress. The plan felt simple enough that everyone was willing to help carry it out.

The final editing session concentrated on removing details that distracted from the main explanation. We read each paragraph aloud and noticed where the sentence structure became difficult to follow. Several technical terms could be replaced with ordinary words without losing accuracy. A long list worked better as two short examples, each connected to a specific decision. We kept the necessary limitations close to the claims they qualified so that readers would not overlook them. The revised document was shorter, but it answered the important questions more clearly. Before sending it, we checked the links and confirmed that the instructions matched the current version of the product.

As the day came to an end, we reviewed the decisions we had made and the work that still needed attention. The useful part of the review was identifying the next concrete action for each unfinished item. We avoided treating a plan as proof that the work had already succeeded. A few tasks needed another person's input, while others could continue independently the following morning. I closed the notebook after checking that the remaining questions were written clearly. The room was quiet again, and the last light outside the window had begun to fade. We were ready to stop because the current state was understood.'''.split('\n\n')
CHINESE = {
  4: '今天我们讨论明天的安排。请先检查时间，再确认参加会议的人。',
  10: '这个例子说明，清楚的说明可以减少误会，也能帮助大家更快完成工作。',
  16: '如果遇到新的问题，不要着急。我们可以先记录情况，然后一起寻找解决办法。',
  22: '请保留原来的意思，不要把中文翻译成英文，也不要增加没有说过的内容。',
  28: '最后再检查一次文件是否完整。确认没有遗漏以后，就可以结束今天的测试。',
}


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''): h.update(block)
    return h.hexdigest()


def render(text, voice, speed, output):
    key=hashlib.sha256(json.dumps([text,voice,speed,RATE],ensure_ascii=False).encode()).hexdigest()
    cache=output/'tts-cache'; cache.mkdir(exist_ok=True)
    wav=cache/(key+'.wav')
    if not wav.exists():
        source=cache/(key+'.txt'); source.write_text(text)
        aiff=cache/(key+'.aiff')
        subprocess.run(['/usr/bin/say','-v',voice,'-r',str(speed),'-f',str(source),'-o',str(aiff)],check=True,stdout=subprocess.DEVNULL,timeout=120)
        subprocess.run(['/usr/bin/afconvert','-f','WAVE','-d','LEI16@24000','-c','1',str(aiff),str(wav)],check=True,stdout=subprocess.DEVNULL,timeout=120)
        aiff.unlink()
    with wave.open(str(wav),'rb') as w:
        if (w.getnchannels(),w.getsampwidth(),w.getframerate()) != (1,2,RATE):
            raise RuntimeError('Unexpected TTS PCM format')
        pcm=w.readframes(w.getnframes())
    # Remove leading/trailing near silence, keeping 120 ms around the voice.
    import array
    samples=array.array('h',pcm)
    if sys.byteorder!='little': samples.byteswap()
    first=next((i for i,x in enumerate(samples) if abs(x)>100),0)
    last=next((len(samples)-i for i,x in enumerate(reversed(samples)) if abs(x)>100),len(samples))
    first=max(0,first-int(.12*RATE)); last=min(len(samples),last+int(.12*RATE))
    return pcm[first*2:last*2]


def longest_quiet(pcm):
    import array
    samples=array.array('h',pcm)
    if sys.byteorder!='little': samples.byteswap()
    frame=RATE//10; current=maximum=0
    for i in range(0,len(samples),frame):
        block=samples[i:i+frame]
        if block and max(abs(x) for x in block)<100:
            current+=len(block); maximum=max(maximum,current)
        else: current=0
    return round(maximum/RATE,3)


def write_fixture(name, minutes, output, smoke=False):
    total_seconds=30 if smoke else minutes*60
    begin='The bilingual smoke test begins with a blue notebook.' if smoke else ('The long recording begins with the blue notebook.' if minutes==30 else 'The continuous recording begins with the blue notebook.')
    end='The bilingual smoke test ends with the green lantern.' if smoke else ('The long recording ends with the green lantern.' if minutes==30 else 'The continuous recording ends with the green lantern.')
    reference=[]; blocks=[]; anchors=[{'kind':'begin','text':begin,'atSeconds':0}]
    wav_path=output/(name+'.wav')
    pending_wav=output/(name+'.pending.wav')
    with wave.open(str(pending_wav),'wb') as wav:
        wav.setparams((1,2,RATE,0,'NONE','not compressed'))
        for i in range(1 if smoke else minutes):
            marker=f'Checkpoint {NUMBERS[i]}, {PAIRS[i]}.'
            english=marker+' '+PARAGRAPHS[i]
            chinese=CHINESE.get(i) if minutes==30 else None
            if smoke:
                english=begin+' Checkpoint one, amber river. We are checking whether the transcript keeps both languages and preserves the words in their original order.'
                chinese='你好，今天我们一起讨论明天的安排，请不要翻译这句话。'
                pieces=[('Samantha',english),('Tingting',chinese),('Samantha',end)]
            else:
                if i==0: english=begin+' '+english
                pieces=[('Samantha',english)]
                if chinese: pieces.append(('Tingting',chinese))
                if i==minutes-1: pieces.append(('Samantha',end))
            slot=30 if smoke else 60
            target=slot-3
            speed=130
            for attempt in range(7):
                rendered=[render(text,voice,speed,output) for voice,text in pieces]
                spoken=b'\0\0'*int(.35*RATE)
                for part in rendered:
                    spoken+=part+b'\0\0'*int(.30*RATE)
                duration=len(spoken)/(RATE*2)
                if slot-14 <= duration <= slot-.5: break
                speed=max(40,min(300,round(speed*duration/target)))
            else: raise RuntimeError(f'{name} block {i+1}: cannot fit speech naturally, duration={duration:.2f}')
            padding_frames=slot*RATE-len(spoken)//2
            if padding_frames<0 or padding_frames>15*RATE: raise RuntimeError('Invalid silence padding')
            pcm=spoken+b'\0\0'*padding_frames
            quiet=longest_quiet(pcm)
            if quiet>15: raise RuntimeError(f'Quiet interval {quiet}s exceeds limit')
            wav.writeframesraw(pcm)
            text='\n'.join(x[1] for x in pieces)
            reference.append(text)
            block={'number':i+1,'startSeconds':i*60,'durationSeconds':slot,'speechAndBriefPauseSeconds':round(duration,3),
                   'tailPauseSeconds':round(padding_frames/RATE,3),'longestQuietSeconds':quiet,'voiceRate':speed,
                   'englishWordCount':len(re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?",text)),
                   'containsMandarin':bool(chinese),'text':text}
            blocks.append(block)
            anchors.append({'kind':'checkpoint','number':i+1,'text':PAIRS[i],'spoken':marker,'atSeconds':i*60})
            if chinese:
                anchors.append({'kind':'mandarin','text':chinese.split('，')[0].split('。')[0],
                                'atSeconds':i*60,'required':False})
            print(f'{name}: block {i+1}/{1 if smoke else minutes}, speech {duration:.1f}s, tail pause {padding_frames/RATE:.1f}s',flush=True)
    with wave.open(str(pending_wav),'rb') as completed:
        global_quiet=longest_quiet(completed.readframes(completed.getnframes()))
    if global_quiet>15:
        raise RuntimeError(f'Quiet interval across minute boundaries is {global_quiet}s')
    pending_wav.replace(wav_path)
    anchors.append({'kind':'end','text':end,'atSeconds':total_seconds-10})
    reference_path=output/(name+'.reference.txt'); reference_path.write_text('\n\n'.join(reference)+'\n')
    manifest={'schemaVersion':1,'fixture':name,'source':'synthetic_offline_tts','notMicrophoneHardwareEvidence':True,
              'audioFile':wav_path.name,'referenceFile':reference_path.name,'sampleRate':RATE,'channels':1,'bitsPerSample':16,
              'durationSeconds':total_seconds,'longestQuietSeconds':global_quiet,'checkpointCount':1 if smoke else minutes,
              'voices':['Samantha','Tingting'] if smoke or minutes==30 else ['Samantha'],
              'macOS':platform.mac_ver()[0],'anchors':anchors,'blocks':blocks,
              'englishWordCount':sum(b['englishWordCount'] for b in blocks),
              'mandarinBlockCount':sum(b['containsMandarin'] for b in blocks),
              'sha256':{'audio':sha(wav_path),'reference':sha(reference_path)}}
    manifest_path=output/(name+'.manifest.json')
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    checksums=output/(name+'.sha256')
    checksums.write_text(''.join(f'{sha(p)}  {p.name}\n' for p in [wav_path,reference_path,manifest_path]))
    print(f'READY {wav_path} ({total_seconds}s; {manifest["checkpointCount"]} checkpoints)',flush=True)


BOUNDARY_TEXT = """The boundary recording begins with a copper notebook. Checkpoint one, turquoise sailboat. Yesterday our research group visited a small maritime museum to examine a collection of handwritten navigation records. The curator brought several folders to a quiet table near the window and explained how the pages had been organized. We began by looking for references to familiar landmarks, because the names of smaller harbors had changed over time. A sketch of the coastline helped us connect a narrow channel on the old map with a modern photograph. Rather than making a quick assumption, we compared the direction of the current and the distance between two rocky islands. Those details suggested that the original description was more accurate than it first appeared. Checkpoint two, bronze magnolia. The next folder contained letters describing the repair of a wooden fishing boat after a storm. The writer listed the materials that were available locally and explained why several replacement pieces had to be ordered from another town. One paragraph described the careful work of shaping a curved board so it would fit against the existing frame without leaving a gap. We noticed that the measurements were repeated in a later letter, which allowed us to check our interpretation against an independent description. The repeated measurements were evidence about the construction, not a reason to copy the surrounding sentences into our own notes. Checkpoint three, orange observatory. We also agreed to keep a clear distinction between direct observations, reasonable interpretations, and questions that still required an answer, so the final report would explain both what the records supported and where additional research might change our view. Before leaving, we photographed the relevant pages with the curator's permission and recorded the folder numbers in our notebook. Back at the office, we planned to compare these observations with the digital catalog and prepare a short explanation of what remained uncertain. Every conclusion needed a source that another person could inspect. The boundary recording ends with a violet lantern."""


def write_boundary_fixture(output):
    import array
    import math
    name='continuous-boundary-125s'
    def rms(samples):
        return math.sqrt(sum(value*value for value in samples)/max(1,len(samples)))
    selected=None
    for speed in [130,135,140,125,145,120,150,115]:
        speech=render(BOUNDARY_TEXT,'Samantha',speed,output)
        speech_duration=len(speech)/(RATE*2)
        if not 122 <= speech_duration <= 130:
            continue
        raw=array.array('h',speech)
        if sys.byteorder!='little': raw.byteswap()
        for pad_frames in range(0,int(.5*RATE),int(.01*RATE)):
            measurements=[]
            for boundary in (60,120):
                center=int(boundary*RATE)-pad_frames
                half=int(.025*RATE)
                before=raw[center-half:center]
                after=raw[center:center+half]
                measurements.append({'atSeconds':boundary,'windowEachSideSeconds':.025,
                                     'rmsBefore':round(rms(before),2),'rmsAfter':round(rms(after),2)})
            if all(item['rmsBefore']>150 and item['rmsAfter']>150 for item in measurements):
                selected=(b'\0\0'*pad_frames+speech,speed,pad_frames/RATE,measurements)
                break
        if selected: break
    if not selected:
        raise RuntimeError('Could not place voiced samples on both sides of 60/120 seconds within target duration')
    pcm,speed,leading_pause,measurements=selected
    duration=len(pcm)/(RATE*2)
    quiet=longest_quiet(pcm)
    if quiet>2:
        raise RuntimeError(f'Unexpected long quiet interval in continuous fixture: {quiet}s')
    path=output/(name+'.wav')
    pending=output/(name+'.pending.wav')
    with wave.open(str(pending),'wb') as wav:
        wav.setparams((1,2,RATE,0,'NONE','not compressed')); wav.writeframes(pcm)
    pending.replace(path)
    reference=output/(name+'.reference.txt'); reference.write_text(BOUNDARY_TEXT+'\n')
    anchors=[{'kind':'begin','text':'The boundary recording begins with a copper notebook.'},
             {'kind':'checkpoint','number':1,'text':'turquoise sailboat'},
             {'kind':'checkpoint','number':2,'text':'bronze magnolia'},
             {'kind':'checkpoint','number':3,'text':'orange observatory'},
             {'kind':'end','text':'The boundary recording ends with a violet lantern.'}]
    manifest={'schemaVersion':1,'fixture':name,'source':'synthetic_offline_tts','notMicrophoneHardwareEvidence':True,
              'audioFile':path.name,'referenceFile':reference.name,'sampleRate':RATE,'channels':1,'bitsPerSample':16,
              'durationSeconds':duration,'checkpointCount':3,'voices':['Samantha'],'macOS':platform.mac_ver()[0],
              'speechPattern':'Single uninterrupted TTS render; natural word/sentence gaps only; no minute padding',
              'leadingPaddingSeconds':leading_pause,'longestQuietSeconds':quiet,'voiceRate':speed,
              'voicedBoundaryMeasurements':measurements,'anchors':anchors,'blocks':[],
              'englishWordCount':len(re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?",BOUNDARY_TEXT)),
              'mandarinBlockCount':0,'sha256':{'audio':sha(path),'reference':sha(reference)}}
    manifest_path=output/(name+'.manifest.json'); manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    (output/(name+'.sha256')).write_text(''.join(f'{sha(p)}  {p.name}\n' for p in [path,reference,manifest_path]))
    print(f'READY {path} ({duration:.6f}s; longest quiet {quiet}s; boundaries {measurements})',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/reliability-fixtures')
    parser.add_argument('--fixture',choices=['all','long-thirty-minute','continuous-seven-minute','bilingual-smoke','continuous-boundary-125s'],default='all')
    args=parser.parse_args(); args.output.mkdir(parents=True,exist_ok=True)
    if len(PARAGRAPHS)!=30: raise RuntimeError('Expected thirty distinct paragraphs')
    choices=[('long-thirty-minute',30,False),('continuous-seven-minute',7,False),('bilingual-smoke',0,True)]
    lock=args.output/'.generation.lock'
    try:
        descriptor=os.open(str(lock),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    except FileExistsError:
        parser.error(f'Another fixture generation owns {lock}; do not generate over an active run')
    try:
        os.close(descriptor)
        for name,minutes,smoke in choices:
            if args.fixture in ('all',name): write_fixture(name,minutes,args.output,smoke)
        if args.fixture in ('all','continuous-boundary-125s'):
            write_boundary_fixture(args.output)
    finally:
        lock.unlink()

if __name__=='__main__': main()

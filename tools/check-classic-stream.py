#!/usr/bin/env python3
"""Drain a live video stream without displaying or saving screen content."""
import argparse
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('phone')
parser.add_argument('--seconds',type=int,default=15)
parser.add_argument('--helper',default=str(Path(__file__).resolve().parents[1]/'outputs/DroidMirror.app/Contents/Helpers/DroidMirrorBluetooth'))
args=parser.parse_args()
process=subprocess.Popen([args.helper,args.phone],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,bufsize=0)
video=control=None
first_frame=last_frame=first_pts=last_pts=None
lines=b''; log=[]; payload=bytearray(); received=frames=configs=0; dimensions=[]; events=[]
def read_log():
    global lines
    block=os.read(process.stdout.fileno(),4096)
    if not block:
        raise RuntimeError('Bridge exited: '+'; '.join(log[-10:]))
    lines+=block
    complete=lines.split(b'\n'); lines=complete.pop()
    decoded=[line.decode(errors='replace') for line in complete]
    log.extend(decoded)
    for line in decoded:
        if line.startswith('EVENT '): events.append(line[6:])
    return decoded
try:
    deadline=time.monotonic()+25
    while time.monotonic()<deadline and video is None:
        if not select.select([process.stdout],[],[],1)[0]: continue
        for line in read_log():
            if line.startswith('READY '):
                _,v,c=line.split(); video=socket.create_connection(('127.0.0.1',int(v))); control=socket.create_connection(('127.0.0.1',int(c)))
    if video is None: raise TimeoutError('Bridge did not authenticate: '+'; '.join(log[-10:]))
    started=time.monotonic(); header=False
    while time.monotonic()-started<args.seconds:
        readable,_,_=select.select([video,control,process.stdout],[],[],1)
        for source in readable:
            if source is process.stdout:
                read_log()
                continue
            block=source.recv(65536)
            if not block: raise RuntimeError('Stream closed: '+'; '.join(log[-10:]))
            if source is control: continue
            received+=len(block); payload.extend(block)
            if not header:
                if len(payload)<69: continue
                if payload[0]!=0 or payload[65:69]!=b'h265': raise ValueError('Expected a hybrid HEVC video header')
                del payload[:69]; header=True
            while len(payload)>=12:
                if payload[0]&0x80:
                    _,width,height=struct.unpack('>III',payload[:12]); dimensions.append((width,height)); del payload[:12]; continue
                size=struct.unpack('>I',payload[8:12])[0]
                if not 0<size<=128*1024: raise ValueError('Invalid video packet')
                if len(payload)<12+size: break
                if payload[0]&0x40: configs+=1
                else:
                    frames+=1
                    last_pts=struct.unpack('>Q',payload[:8])[0] & ((1<<61)-1)
                    if first_pts is None: first_pts=last_pts
                    last_frame=time.monotonic()
                    if first_frame is None: first_frame=last_frame
                del payload[:12+size]
    elapsed=time.monotonic()-started
    steady=(frames-1)/(last_frame-first_frame) if frames>1 and last_frame>first_frame else 0
    drift=((last_frame-first_frame)-(last_pts-first_pts)/1000000)*1000 if frames>1 else 0
    print(f'STREAM lagGrowthMs={drift:.1f} steadyFps={steady:.2f} bytes={received} frames={frames} seconds={elapsed:.3f} receivedFps={frames/elapsed:.2f} kbps={received*8/elapsed/1000:.1f} dimensions={dimensions} configs={configs} events={events}')
    if not frames or 'STREAM_STARTED' not in events: raise RuntimeError('Video or BLE stream-start event missing: '+'; '.join(log[-10:]))
finally:
    if video: video.close()
    if control: control.close()
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill()

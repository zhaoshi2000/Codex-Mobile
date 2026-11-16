"""Stateful, CPU-only streaming ASR; audio is discarded after each chunk."""
import asyncio
import base64
import hashlib
import os
import re
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
from fastapi import FastAPI, HTTPException, Request
from starlette.concurrency import run_in_threadpool

class Streams:
    def __init__(self, recognizer, now=time.monotonic):
        self.recognizer = recognizer
        self.now = now
        self.sessions = {}
        self.lock = threading.Lock()

    def clean(self):
        self.sessions = {k: v for k, v in self.sessions.items() if self.now() - v['at'] < 90}

    def accept(self, p):
        ident, sequence, encoded = p.get('requestId'), p.get('sequence'), p.get('audio')
        final, cancel = p.get('final'), p.get('cancel', False)
        if not isinstance(ident, str) or not re.fullmatch(r'[a-zA-Z0-9-]{16,80}', ident):
            raise HTTPException(422, 'invalid_session')
        if type(sequence) is not int or not 0 <= sequence <= 240 or not isinstance(encoded, str) or len(encoded) > 85336 or type(final) is not bool or type(cancel) is not bool:
            raise HTTPException(422, 'invalid_chunk')
        try:
            audio = base64.b64decode(encoded, validate=True)
        except Exception:
            raise HTTPException(422, 'invalid_audio')
        if len(audio) > 64000 or len(audio) % 2 or (not audio and not final and not cancel):
            raise HTTPException(422, 'invalid_audio_size')
        if not self.lock.acquire(blocking=False):
            raise HTTPException(503, 'busy')
        try:
            self.clean()
            if cancel:
                self.sessions.pop(ident, None)
                return {'text': '', 'sequence': sequence, 'final': True}
            session = self.sessions.get(ident)
            digest = hashlib.sha256(audio + bytes([final])).hexdigest()
            if session is None:
                if sequence != 0:
                    raise HTTPException(409, 'session_expired')
                if sum(v['stream'] is not None for v in self.sessions.values()) >= 4 or len(self.sessions) >= 64:
                    raise HTTPException(503, 'busy')
                session = {'stream': self.recognizer.create_stream(), 'seq': -1, 'samples': 0, 'committed': [], 'at': self.now()}
                self.sessions[ident] = session
            if sequence == session['seq']:
                if digest != session['digest']:
                    raise HTTPException(409, 'chunk_conflict')
                return session['result']
            if sequence != session['seq'] + 1 or session['stream'] is None:
                raise HTTPException(409, 'chunk_order')
            if session['samples'] + len(audio) // 2 > 16000 * 61:
                raise HTTPException(413, 'recording_too_long')
            stream = session['stream']
            if audio:
                stream.accept_waveform(16000, np.frombuffer(audio, dtype='<i2').astype(np.float32) / 32768)
            if final:
                stream.accept_waveform(16000, np.zeros(9600, dtype=np.float32))
                stream.input_finished()
            while self.recognizer.is_ready(stream):
                self.recognizer.decode_stream(stream)
            current = self.recognizer.get_result(stream).strip()
            # Commit a pause-delimited utterance exactly once, then reset the
            # decoder. Do not keep decoding a minute-long hypothesis or remove
            # repeated words from the user's actual speech.
            if not final and self.recognizer.is_endpoint(stream):
                if current: session['committed'].append(current)
                self.recognizer.reset(stream)
                current = ''
            text = ' '.join(session['committed'] + ([current] if current else []))
            result = {'text': text, 'sequence': sequence, 'final': final}
            session.update(seq=sequence, samples=session['samples'] + len(audio) // 2,
                           at=self.now(), result=result, digest=digest)
            if final:
                session['stream'] = None
            return result
        finally:
            self.lock.release()


streams = None

@asynccontextmanager
async def lifespan(app):
    global streams
    import sherpa_onnx
    root = Path(os.environ.get('SPEECH_MODEL', '/opt/astrogate-speech/model'))
    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=str(root/'tokens.txt'), encoder=str(root/'encoder-epoch-99-avg-1.int8.onnx'),
        decoder=str(root/'decoder-epoch-99-avg-1.int8.onnx'), joiner=str(root/'joiner-epoch-99-avg-1.int8.onnx'),
        num_threads=int(os.environ.get('SPEECH_THREADS', '4')), sample_rate=16000, feature_dim=80,
        decoding_method='modified_beam_search', max_active_paths=4, enable_endpoint_detection=True,
        rule1_min_trailing_silence=2.4, rule2_min_trailing_silence=1.2, rule3_min_utterance_length=15,
        provider='cpu', model_type='zipformer')
    streams = Streams(recognizer)
    async def cleanup():
        while True:
            await asyncio.sleep(15)
            if streams.lock.acquire(blocking=False):
                try: streams.clean()
                finally: streams.lock.release()
    task = asyncio.create_task(cleanup())
    try:
        yield
    finally:
        task.cancel()

app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

@app.get('/health')
def health():
    return {'ready': streams is not None, 'device': 'cpu', 'streaming': True}

@app.post('/stream')
async def stream(request: Request):
    try: length = int(request.headers.get('content-length', '0'))
    except ValueError: raise HTTPException(413, 'audio_size')
    if not 1 <= length <= 90000: raise HTTPException(413, 'audio_size')
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > 90000: raise HTTPException(413, 'audio_size')
    if len(data) != length: raise HTTPException(422, 'incomplete_audio')
    import json
    try: payload = json.loads(data)
    except Exception: raise HTTPException(422, 'invalid_json')
    if not isinstance(payload, dict): raise HTTPException(422, 'invalid_json')
    return await run_in_threadpool(streams.accept, payload)

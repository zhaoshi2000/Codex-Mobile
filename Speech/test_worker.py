import base64
import unittest
from fastapi import HTTPException
from worker import Streams


class Stream:
    def __init__(self): self.count = 0
    def accept_waveform(self, rate, samples): self.count += len(samples)
    def input_finished(self): pass


class Recognizer:
    def create_stream(self): return Stream()
    def is_ready(self, stream): return False
    def get_result(self, stream): return f"文字 {stream.count}"
    def is_endpoint(self, stream): return False
    def reset(self, stream): stream.count = 0


class StreamingTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0
        self.worker = Streams(Recognizer(), now=lambda: self.clock)
        self.chunk = dict(requestId='12345678-1234-1234-1234-123456789abc', sequence=0,
                          audio=base64.b64encode(bytes(3200)).decode(), final=False)

    def test_partial_then_final_and_retry_never_duplicates_audio(self):
        first = self.worker.accept(self.chunk)
        self.assertFalse(first['final'])
        self.assertEqual(first, self.worker.accept(self.chunk))
        self.assertEqual(self.worker.sessions[self.chunk['requestId']]['samples'], 1600)
        final = dict(self.chunk, sequence=1, audio='', final=True)
        result = self.worker.accept(final)
        self.assertTrue(result['final'])
        self.assertEqual(result, self.worker.accept(final))
        self.assertIsNone(self.worker.sessions[self.chunk['requestId']]['stream'])

    def test_reordered_and_changed_chunks_are_rejected(self):
        with self.assertRaises(HTTPException): self.worker.accept(dict(self.chunk, sequence=1))
        self.worker.accept(self.chunk)
        with self.assertRaises(HTTPException): self.worker.accept(dict(self.chunk, audio='AAAAAA=='))
        with self.assertRaises(HTTPException): self.worker.accept(dict(self.chunk, sequence=2))

    def test_cancel_expiry_isolation_and_boundaries(self):
        self.worker.accept(self.chunk)
        other = dict(self.chunk, requestId='12345678-1234-1234-1234-123456789def')
        self.worker.accept(other)
        self.worker.accept(dict(self.chunk, audio='', cancel=True))
        self.assertNotIn(self.chunk['requestId'], self.worker.sessions)
        self.assertIn(other['requestId'], self.worker.sessions)
        self.clock = 91; self.worker.clean(); self.assertEqual(self.worker.sessions, {})
        for change in [dict(audio='?'), dict(audio='AA=='), dict(sequence=True), dict(final='yes'),
                       dict(audio=base64.b64encode(bytes(64002)).decode())]:
            with self.assertRaises(HTTPException): self.worker.accept(dict(self.chunk, **change))

    def test_endpoint_resets_once_and_partial_snapshots_do_not_append(self):
        class EndpointRecognizer(Recognizer):
            def is_endpoint(self, stream): return stream.count >= 3200
            def get_result(self, stream): return '看看' if stream.count else ''
        worker = Streams(EndpointRecognizer())
        first = worker.accept(self.chunk)
        self.assertEqual(first['text'], '看看')
        boundary = dict(self.chunk, sequence=1)
        result = worker.accept(boundary)
        self.assertEqual(result['text'], '看看')
        self.assertEqual(worker.accept(boundary), result)
        self.assertEqual(len(worker.sessions[self.chunk['requestId']]['committed']), 1)
        next_result = worker.accept(dict(self.chunk, sequence=2))
        self.assertEqual(next_result['text'], '看看 看看')
        self.assertEqual(worker.sessions[self.chunk['requestId']]['stream'].count, 1600)

    def test_capacity_and_duration_are_bounded(self):
        for n in range(4):
            self.worker.accept(dict(self.chunk, requestId=f'12345678-1234-1234-1234-123456789ab{n}'))
        with self.assertRaises(HTTPException): self.worker.accept(self.chunk)
        session = next(iter(self.worker.sessions.values()))
        session['samples'] = 16000 * 61
        with self.assertRaises(HTTPException):
            self.worker.accept(dict(self.chunk, requestId=next(iter(self.worker.sessions)), sequence=1))


if __name__ == '__main__': unittest.main()

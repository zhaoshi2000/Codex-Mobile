// PCM chunks are carried inside the existing paired/encrypted phone channel.
export const MAX_SPEECH_BYTES = 64000; // Two seconds of 16 kHz mono PCM16.
export const MAX_SPEECH_BODY = 90000;
export function validateSpeech(p) {
  if (!p || typeof p.requestId !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(p.requestId) ||
      !Number.isInteger(p.sequence) || p.sequence < 0 || p.sequence > 240 ||
      typeof p.audio !== 'string' || p.audio.length > 85336 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(p.audio) || typeof p.final !== 'boolean' ||
      (p.cancel !== undefined && typeof p.cancel !== 'boolean')) throw Error('语音分片格式无效，请重新录音');
  const bytes = Buffer.from(p.audio, 'base64');
  if (bytes.length > MAX_SPEECH_BYTES || bytes.length % 2 || bytes.toString('base64') !== p.audio ||
      (!bytes.length && !p.final && !p.cancel)) throw Error('语音分片为空或过大，请重新录音');
  return { requestId: p.requestId, sequence: p.sequence, audio: p.audio, final: p.final, cancel: p.cancel === true };
}
export function speechClient({ relay, token, fetchImpl = fetch }) {
  return async (params) => {
    if (!token || !relay) throw Error('电脑尚未配置语音中转，请更新电脑连接程序');
    const chunk = validateSpeech(params);
    const url = new URL(relay.replace(/^wss:/, 'https:'));
    if (url.protocol !== 'https:' || url.username || url.password) throw Error('语音中转需要 HTTPS 加密连接');
    url.pathname = url.pathname.replace(/\/$/, '') + '/speech'; url.search = ''; url.hash = '';
    try {
      const response = await fetchImpl(url, {
        method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify(chunk), redirect: 'error', signal: AbortSignal.timeout(15000),
      });
      if (response.status === 404) throw Error('中转服务器尚未启用实时语音识别');
      if (response.status === 401 || response.status === 403) throw Error('语音中转验证失败，请检查电脑连接配置');
      if (response.status === 429 || response.status === 503) throw Error('语音识别电脑离线或繁忙，请稍后重试');
      if (response.status === 409) throw Error('语音连接已过期，请重新录音；已识别文字已保留');
      if (response.status === 504) throw Error('语音识别超时，请检查识别电脑的网络');
      if (!response.ok) throw Error('语音识别失败，请重新录音；已识别文字已保留');
      const result = await response.json();
      if (typeof result.text !== 'string' || result.text.length > 12000 || result.sequence !== chunk.sequence)
        throw Error('语音服务返回了无效结果');
      return { text: result.text.trim(), sequence: result.sequence, final: result.final === true };
    } catch (error) {
      if (error.name === 'TimeoutError' || error.name === 'AbortError') throw Error('语音识别超时，请稍后重试');
      if (error instanceof TypeError) throw Error('无法连接语音中转，请检查网络和识别电脑是否在线');
      throw error;
    }
  };
}

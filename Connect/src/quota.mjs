// Only expose published usage windows, never account IDs or provider credentials.
export function quotaSummary(response, now = Date.now()) {
  const map = response?.rateLimitsByLimitId;
  const limits = map && Object.keys(map).length ? Object.values(map) : response?.rateLimits ? [response.rateLimits] : [];
  const windows = [];
  for (const limit of limits) {
    for (const kind of ['primary', 'secondary']) {
      const value = limit?.[kind];
      if (!value || typeof value.usedPercent !== 'number' || !Number.isFinite(value.usedPercent)) continue;
      const minutes = value.windowDurationMins;
      const duration = minutes === 10080 ? '周额度' : minutes === 300 ? '5 小时额度' : Number.isFinite(minutes) && minutes > 0 ? `${minutes >= 60 && minutes % 60 === 0 ? minutes / 60 + ' 小时' : minutes + ' 分钟'}额度` : kind === 'primary' ? '主要额度' : '额外额度';
      windows.push({id: `${limit.limitId || 'codex'}:${kind}`, label: `${limit.limitName ? limit.limitName + ' · ' : ''}${duration}`, remainingPercent: Math.max(0, Math.min(100, 100 - value.usedPercent)), resetsAt: Number.isFinite(value.resetsAt) && value.resetsAt > 0 ? value.resetsAt : null});
    }
  }
  return {available: windows.length > 0, windows, checkedAt: now, message: windows.length ? '' : '此 Codex 账号未提供可显示的剩余额度。'};
}

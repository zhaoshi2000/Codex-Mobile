import { createHash } from "node:crypto";
export function parseQuestionReply(text) {
  if (typeof text !== "string") return null;
  const match = text.trim().match(/^<send_user_message_question_reply>\s*([\s\S]*?)\s*<\/send_user_message_question_reply>$/);
  if (!match) return null;
  try { const a = JSON.parse(match[1]); return Array.isArray(a) && a.every(x => typeof x.questionItemId === "string" && typeof x.question === "string" && typeof x.answer === "string") ? a : null; } catch { return null; }
}
const hash = x => createHash("sha256").update(JSON.stringify(x)).digest("hex").slice(0, 32);
export function questionGroups(state, turns) {
  const groups = [];
  for (const request of state?.requests || []) {
    if (request.completed || request.method !== "item/tool/requestUserInput") continue;
    const qs = request.params?.questions;
    if (!Array.isArray(qs) || !qs.length || qs.length > 10) continue;
    const questions = qs.map(q => ({ id: q.id, title: q.question, secret: !!q.isSecret, options: (q.options || []).map(o => ({ label: o.label, description: o.description || "" })) }));
    if (!questions.every(q => typeof q.id === "string" && typeof q.title === "string")) continue;
    groups.push({ id: hash(["sync", request.id, questions]), kind: "sync", requestId: request.id, questions });
  }
  // Async questions belong to the latest original user turn; answers may be steers.
  const turn = turns.at(-1); const answered = new Set();
  for (const i of turn?.items || []) {
    if (i.type !== "userMessage" && !(i.type === "steeringUserMessage" && (i.status === "accepted" || i.steerAcknowledged))) continue;
    const text = (i.content || i.input || []).filter(x => x.type === "text").map(x => x.text).join("\n");
    for (const r of parseQuestionReply(text) || []) answered.add(r.questionItemId);
  }
  for (const i of turn?.items || []) {
    if (i.type !== "agentMessage" || !Array.isArray(i.questions) || !i.questions.length) continue;
    const questions = i.questions.map((q, index) => ({ id: JSON.stringify(["request_user_input_async", i.id, index]), title: q.title, secret: false, options: (q.options || []).map(label => ({ label, description: "" })) })).filter(q => !answered.has(q.id));
    if (questions.length) groups.push({ id: hash(["async", i.id, questions]), kind: "async", questions });
  }
  return groups.slice(-10);
}
export function questionAnswer(group, answers) {
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) throw Error("答案格式无效");
  if (Object.keys(answers).length !== group.questions.length) throw Error("请回答全部问题");
  const replies = group.questions.map(q => {
    const answer = answers[q.id];
    if (typeof answer !== "string" || !answer.trim() || answer.length > 8000) throw Error("请填写答案（最多 8000 字符）");
    return { questionItemId: q.id, question: q.title, answer: answer.trim() };
  });
  if (group.kind === "sync") return { answers: Object.fromEntries(replies.map(r => [r.questionItemId, { answers: [r.answer] }])) };
  return "<send_user_message_question_reply>\n" + JSON.stringify(replies) + "\n</send_user_message_question_reply>";
}

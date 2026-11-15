import {
  generateKeyPairSync,
  createPublicKey,
  createPrivateKey,
  diffieHellman,
  hkdfSync,
  createHash,
  randomBytes,
  createCipheriv,
  createDecipheriv,
} from "node:crypto";
export function identity() {
  const { privateKey } = generateKeyPairSync("x25519");
  return privateKey.export({ format: "jwk" });
}
export function sessionKey(jwk, peer, host, sid) {
  const shared = diffieHellman({
    privateKey: createPrivateKey({ key: jwk, format: "jwk" }),
    publicKey: createPublicKey({
      key: { kty: "OKP", crv: "X25519", x: peer },
      format: "jwk",
    }),
  });
  return Buffer.from(
    hkdfSync(
      "sha256",
      shared,
      createHash("sha256")
        .update(host + "|" + sid)
        .digest(),
      Buffer.from("ifile-connect-v1"),
      32,
    ),
  );
}
export class SecureSession {
  constructor(key, host, sid, outDirection) {
    this.key = key;
    this.host = host;
    this.sid = sid;
    this.outDirection = outDirection;
    this.sent = 0;
    this.received = 0;
  }
  aad(direction, seq) {
    return Buffer.from(`${this.host}|${this.sid}|${direction}|${seq}`);
  }
  seal(value) {
    const seq = ++this.sent,
      nonce = randomBytes(12);
    const c = createCipheriv("aes-256-gcm", this.key, nonce);
    c.setAAD(this.aad(this.outDirection, seq));
    const body = Buffer.concat([
      c.update(JSON.stringify(value), "utf8"),
      c.final(),
      c.getAuthTag(),
    ]);
    return {
      seq,
      nonce: nonce.toString("base64"),
      body: body.toString("base64"),
    };
  }
  open(box) {
    if (!Number.isSafeInteger(box.seq) || box.seq !== this.received + 1)
      throw new Error("消息序号不连续，请重新连接");
    const nonce = Buffer.from(box.nonce || "", "base64"),
      body = Buffer.from(box.body || "", "base64");
    if (nonce.length !== 12 || body.length < 16 || body.length > 900000)
      throw new Error("加密消息格式错误");
    const c = createDecipheriv("aes-256-gcm", this.key, nonce);
    c.setAAD(this.aad(this.outDirection === "h2c" ? "c2h" : "h2c", box.seq));
    c.setAuthTag(body.subarray(-16));
    const plain = Buffer.concat([c.update(body.subarray(0, -16)), c.final()]);
    const value = JSON.parse(plain.toString("utf8"));
    this.received = box.seq;
    return value;
  }
}

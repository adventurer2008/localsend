import { createPublicKey, randomBytes, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

const authPrefix = 'localsend-relay/auth/v1';
const maxPayload = 360_000; // A 256 KiB encrypted chunk plus base64 and JSON.
const transferId = /^[a-f0-9]{32}$/;
const publicId = /^[A-Za-z0-9_-]{43}$/;
const encodedBody = /^[A-Za-z0-9_-]+$/;
const ed25519DerPrefix = Buffer.from('302a300506032b6570032100', 'hex');

function decode(value, length) {
  if (typeof value !== 'string' || !encodedBody.test(value)) return null;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.length === length && bytes.toString('base64url') === value ? bytes : null;
}

export function createRelay(allowedIds) {
  if (!Array.isArray(allowedIds) || allowedIds.length === 0 || allowedIds.length > 32) {
    throw new Error('The allowlist must contain 1 to 32 Ed25519 public keys');
  }
  const keys = new Map(allowedIds.map((id) => {
    const bytes = decode(id, 32);
    if (!bytes) throw new Error('Invalid Ed25519 public key in allowlist');
    return [id, createPublicKey({ key: Buffer.concat([ed25519DerPrefix, bytes]), format: 'der', type: 'spki' })];
  }));
  if (keys.size !== allowedIds.length) throw new Error('Duplicate key in allowlist');

  const server = createServer((req, res) => {
    res.writeHead(req.method === 'GET' && req.url === '/health' ? 200 : 404).end();
  });
  const sockets = new WebSocketServer({ noServer: true, maxPayload, perMessageDeflate: false });
  const peers = new Map();
  const active = new Map();
  server.on('upgrade', (req, socket, head) => {
    if (req.url !== '/v1/relay' || sockets.clients.size >= keys.size + 32) {
      socket.destroy();
      return;
    }
    sockets.handleUpgrade(req, socket, head, (ws) => sockets.emit('connection', ws));
  });

  function send(client, frame) {
    if (client.ws.readyState !== WebSocket.OPEN) return;
    if (client.ws.bufferedAmount > maxPayload * 2) {
      client.ws.terminate();
      return;
    }
    client.ws.send(JSON.stringify(frame));
  }

  function announce() {
    const online = Array.from(peers.values(), ({ id, epoch }) => ({ id, epoch }));
    for (const client of peers.values()) send(client, { type: 'peers', online });
  }

  function release(transfer) {
    clearTimeout(transfer.timeout);
    active.delete(transfer.sender.id);
    active.delete(transfer.receiver.id);
  }

  function abort(transfer, reason) {
    release(transfer);
    for (const client of [transfer.sender, transfer.receiver]) {
      send(client, { type: 'aborted', session: transfer.id, reason });
    }
  }

  function arm(transfer) {
    clearTimeout(transfer.timeout);
    transfer.timeout = setTimeout(() => abort(transfer, 'Transfer timed out'), 90_000);
  }

  function control(client, frame) {
    const { type, session, to, epoch, seq, body } = frame;
    if (typeof type !== 'string' || typeof session !== 'string' || !transferId.test(session)) throw new Error('Invalid session');
    let transfer = active.get(client.id);
    if (type === 'abort') {
      if (transfer?.id === session) abort(transfer, 'Transfer cancelled');
      return;
    }
    if (!Number.isSafeInteger(seq) || seq < 0 || typeof body !== 'string' || body.length < 38 || !encodedBody.test(body)) {
      throw new Error('Invalid encrypted frame');
    }

    if (type === 'offer') {
      const receiver = peers.get(to);
      if (transfer || !receiver || receiver === client || receiver.epoch !== epoch || active.has(to)) {
        send(client, { type: 'aborted', session, reason: 'Device is offline or busy' });
        return;
      }
      if (seq !== 0 || body.length > 8192) throw new Error('Invalid offer');
      transfer = { id: session, sender: client, receiver, phase: 'decision', senderSeq: 1, receiverSeq: 0 };
      active.set(client.id, transfer);
      active.set(receiver.id, transfer);
      send(receiver, { type, session, from: client.id, seq, body });
      arm(transfer);
      return;
    }
    // Frames can still arrive after a simultaneous cancellation.
    if (transfer?.id !== session) return;
    const sending = client === transfer.sender;
    const counter = sending ? 'senderSeq' : 'receiverSeq';
    if (seq !== transfer[counter] || (type !== 'chunk' && body.length > 8192)) throw new Error('Unexpected frame');
    const transition = {
      decision: sending ? {} : { accept: 'data', decline: 'closed' },
      data: sending ? { chunk: 'ack', finish: 'receipt' } : {},
      ack: sending ? {} : { ack: 'data' },
      receipt: sending ? {} : { receipt: 'closed' },
    }[transfer.phase];
    if (!Object.hasOwn(transition, type)) throw new Error('Unexpected transfer state');

    transfer[counter]++;
    transfer.phase = transition[type];
    const peer = sending ? transfer.receiver : transfer.sender;
    send(peer, { type, session, from: client.id, seq, body });
    if (transfer.phase === 'closed') release(transfer);
    else arm(transfer);
  }

  sockets.on('connection', (ws) => {
    const nonce = randomBytes(32).toString('base64url');
    const client = { ws, id: null, epoch: null, alive: true };
    const loginTimeout = setTimeout(() => ws.close(1008, 'Authentication timed out'), 8000);
    ws.on('pong', () => { client.alive = true; });
    ws.on('error', () => ws.terminate());
    ws.on('close', () => {
      clearTimeout(loginTimeout);
      if (!client.id || peers.get(client.id) !== client) return;
      peers.delete(client.id);
      const transfer = active.get(client.id);
      if (transfer) abort(transfer, 'Device disconnected');
      announce();
    });
    ws.on('message', (raw, binary) => {
      try {
        if (binary) throw new Error('Expected text frame');
        const frame = JSON.parse(raw.toString());
        if (client.id) {
          control(client, frame);
          return;
        }
        const { type, id, epoch, signature } = frame;
        const key = typeof id === 'string' && publicId.test(id) ? keys.get(id) : null;
        const proof = decode(signature, 64);
        if (type !== 'auth' || !key || !decode(epoch, 16) || !proof ||
            !verify(null, Buffer.from(`${authPrefix}:${nonce}:${epoch}`), key, proof)) {
          throw new Error('Authentication rejected');
        }
        clearTimeout(loginTimeout);
        const previous = peers.get(id);
        if (previous) {
          const transfer = active.get(id);
          if (transfer) abort(transfer, 'Device reconnected');
          previous.ws.terminate();
        }
        client.id = id;
        client.epoch = epoch;
        peers.set(id, client);
        send(client, { type: 'ready' });
        announce();
      } catch {
        ws.close(1008, 'Authentication or protocol rejected');
      }
    });
    send(client, { type: 'challenge', nonce });

    const heartbeat = setInterval(() => {
      if (!client.alive) ws.terminate();
      else if (ws.readyState === WebSocket.OPEN) {
        client.alive = false;
        ws.ping();
      }
    }, 25_000);
    ws.once('close', () => clearInterval(heartbeat));
  });

  return { server, close: () => {
    for (const socket of sockets.clients) socket.terminate();
    sockets.close();
    return new Promise((resolve) => server.close(resolve));
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const allowlist = JSON.parse(readFileSync(process.env.RELAY_ALLOWLIST || 'allowlist.json', 'utf8').trim());
  const host = process.env.RELAY_HOST || '127.0.0.1';
  const port = Number(process.env.RELAY_PORT || 8787);
  const { server } = createRelay(allowlist);
  server.listen(port, host, () => console.log(`LocalSend relay listening on ${host}:${port}`));
}

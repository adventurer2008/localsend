import { createPublicKey, randomBytes, verify } from 'node:crypto';
import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

const authPrefix = 'localsend-relay/auth/v1';
const maxPayload = 360_000; // A 256 KiB encrypted chunk plus base64 and JSON.
const chunkWindow = 8;
const transferId = /^[a-f0-9]{32}$/;
const publicId = /^[A-Za-z0-9_-]{43}$/;
const encodedBody = /^[A-Za-z0-9_-]+$/;
const ed25519DerPrefix = Buffer.from('302a300506032b6570032100', 'hex');

function decode(value, length) {
  if (typeof value !== 'string' || !encodedBody.test(value)) return null;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.length === length && bytes.toString('base64url') === value ? bytes : null;
}

export function createRelay(allowedIds, { directoryPath } = {}) {
  if (!Array.isArray(allowedIds) || allowedIds.length === 0 || allowedIds.length > 32) {
    throw new Error('The allowlist must contain 1 to 32 Ed25519 public keys');
  }
  const keys = new Map(allowedIds.map((id) => {
    const bytes = decode(id, 32);
    if (!bytes) throw new Error('Invalid Ed25519 public key in allowlist');
    return [id, createPublicKey({ key: Buffer.concat([ed25519DerPrefix, bytes]), format: 'der', type: 'spki' })];
  }));
  if (keys.size !== allowedIds.length) throw new Error('Duplicate key in allowlist');

  function verifiedCard(id, card, signature) {
    if (typeof card !== 'string' || card.length > 1024 || typeof id !== 'string') return null;
    const fields = card.split('.');
    const proof = decode(signature, 64);
    if (fields.length !== 5 || fields[0] !== 'lsr1' || fields[2] !== id || !keys.has(id) || !proof ||
        !decode(fields[3], 32) || !/^[A-Fa-f0-9]{64}$/.test(fields[4])) return null;
    try {
      const name = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(fields[1], 'base64url'));
      if (!name.trim() || name.length > 64 || /[\x00-\x1f\x7f]/.test(name) ||
          Buffer.from(name).toString('base64url') !== fields[1]) return null;
    } catch { return null; }
    if (!verify(null, Buffer.from(`localsend-relay/card/v1:${card}`), keys.get(id), proof)) return null;
    return { id, card, signature };
  }

  const directory = new Map();
  if (directoryPath) {
    try {
      const saved = JSON.parse(readFileSync(directoryPath, 'utf8').trim());
      if (Array.isArray(saved)) {
        for (const entry of saved) {
          const valid = verifiedCard(entry?.id, entry?.card, entry?.signature);
          if (valid) directory.set(valid.id, valid);
        }
      }
    } catch (error) {
      if (error.code !== 'ENOENT') console.warn('Device directory cache could not be read; devices will republish when they connect');
    }
  }

  function saveCard(entry) {
    directory.set(entry.id, entry);
    if (directoryPath) {
      try {
        const temporary = directoryPath + '.tmp';
        writeFileSync(temporary, JSON.stringify(Array.from(directory.values())));
        renameSync(temporary, directoryPath);
      } catch {
        console.warn('Device directory cache could not be saved');
      }
    }
  }

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
    if (client.ws.bufferedAmount > maxPayload * (chunkWindow + 2)) {
      client.ws.terminate();
      return;
    }
    client.ws.send(JSON.stringify(frame));
  }

  function announce() {
    const online = Array.from(peers.values(), ({ id, epoch }) => ({ id, epoch }));
    const devices = Array.from(directory.values());
    for (const client of peers.values()) send(client, { type: 'peers', online, directory: devices });
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
      transfer = { id: session, sender: client, receiver, phase: 'decision', senderSeq: 1, receiverSeq: 0, pendingChunks: 0 };
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
      data: sending
        ? { chunk: transfer.pendingChunks < chunkWindow ? 'data' : null, finish: transfer.pendingChunks === 0 ? 'receipt' : null }
        : { ack: transfer.pendingChunks > 0 ? 'data' : null },
      receipt: sending ? {} : { receipt: 'closed' },
    }[transfer.phase];
    if (!Object.hasOwn(transition, type) || !transition[type]) throw new Error('Unexpected transfer state');

    transfer[counter]++;
    if (type === 'chunk') transfer.pendingChunks++;
    if (type === 'ack') transfer.pendingChunks--;
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
        const { type, id, epoch, signature, card, cardSignature } = frame;
        const key = typeof id === 'string' && publicId.test(id) ? keys.get(id) : null;
        const proof = decode(signature, 64);
        if (type !== 'auth' || !key || !decode(epoch, 16) || !proof ||
            !verify(null, Buffer.from(`${authPrefix}:${nonce}:${epoch}`), key, proof)) {
          throw new Error('Authentication rejected');
        }
        if (card !== undefined || cardSignature !== undefined) {
          const entry = verifiedCard(id, card, cardSignature);
          if (!entry) throw new Error('Device card rejected');
          saveCard(entry);
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
        send(client, { type: 'ready', directoryVersion: 1, chunkWindow });
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
  const directoryPath = process.env.RELAY_DIRECTORY || join(dirname(process.env.RELAY_ALLOWLIST || 'allowlist.json'), 'devices.json');
  const { server } = createRelay(allowlist, { directoryPath });
  server.listen(port, host, () => console.log(`LocalSend relay listening on ${host}:${port}`));
}

import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { EventEmitter, once } from 'node:events';
import { test } from 'node:test';
import { WebSocket } from 'ws';
import { createRelay } from './server.mjs';

function identity() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { id: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url'), privateKey };
}

function login(url, device, privateKey = device.privateKey) {
  const socket = new WebSocket(url);
  const epoch = randomBytes(16).toString('base64url');
  const messages = [];
  const events = new EventEmitter();
  const ready = new Promise((resolve) => {
    socket.on('message', (data) => {
      const frame = JSON.parse(data);
      messages.push(frame);
      if (frame.type === 'challenge') {
        const proof = sign(null, Buffer.from(`localsend-relay/auth/v1:${frame.nonce}:${epoch}`), privateKey);
        socket.send(JSON.stringify({ type: 'auth', id: device.id, epoch, signature: proof.toString('base64url') }));
      }
      if (frame.type === 'ready') resolve(true);
      events.emit(frame.type, frame);
    });
    socket.on('close', () => {
      resolve(false);
    });
  });
  return { socket, epoch, messages, ready, events };
}

test('The relay checks proof of identity and rejects file data before the receiver accepts', { timeout: 5000 }, async () => {
  const alice = identity();
  const bob = identity();
  const other = identity();
  const relay = createRelay([alice.id, bob.id]);
  try {
    relay.server.listen(0, '127.0.0.1');
    await once(relay.server, 'listening');
    const url = `ws://127.0.0.1:${relay.server.address().port}/v1/relay`;
    assert.equal(await login(url, other).ready, false);
    assert.equal(await login(url, alice, other.privateKey).ready, false);

    const sender = login(url, alice);
    const receiver = login(url, bob);
    assert.deepEqual(await Promise.all([sender.ready, receiver.ready]), [true, true]);
    const session = randomBytes(16).toString('hex');
    const body = randomBytes(32).toString('base64url');
    const offer = { type: 'offer', session, to: bob.id, epoch: receiver.epoch, seq: 0, body };
    const firstOffer = once(receiver.events, 'offer');
    sender.socket.send(JSON.stringify(offer));
    const [received] = await firstOffer;
    assert.equal(received.body, body);

    const closed = once(sender.socket, 'close');
    const aborted = once(receiver.events, 'aborted');
    sender.socket.send(JSON.stringify({ type: 'chunk', session, seq: 1, body }));
    assert.equal((await closed)[0], 1008);
    assert.equal((await aborted)[0].session, session);
    assert.equal(receiver.messages.some((frame) => frame.type === 'chunk'), false);
  } finally {
    await relay.close();
  }
});

import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { EventEmitter, once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { WebSocket } from 'ws';
import { createRelay } from './server.mjs';

function identity() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { id: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url'), privateKey };
}

function login(url, device, privateKey = device.privateKey, cardFields = {}) {
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
        socket.send(JSON.stringify({ type: 'auth', id: device.id, epoch, signature: proof.toString('base64url'), ...cardFields }));
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

function signedCard(device, name) {
  const exchange = generateKeyPairSync('x25519').publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url');
  const card = `lsr1.${Buffer.from(name).toString('base64url')}.${device.id}.${exchange}.${randomBytes(32).toString('hex')}`;
  return { card, cardSignature: sign(null, Buffer.from(`localsend-relay/card/v1:${card}`), device.privateKey).toString('base64url') };
}

async function waitForFrame(client, type, predicate) {
  for (let attempt = 0; attempt < 300; attempt++) {
    const frame = client.messages.findLast((entry) => entry.type === type && predicate(entry));
    if (frame) return frame;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Expected ${type} frame was not received`);
}

test('Ten whitelisted devices receive the complete directory after one enrollment each', { timeout: 5000 }, async () => {
  const devices = Array.from({ length: 10 }, () => identity());
  const relay = createRelay(devices.map((device) => device.id));
  try {
    relay.server.listen(0, '127.0.0.1');
    await once(relay.server, 'listening');
    const url = `ws://127.0.0.1:${relay.server.address().port}/v1/relay`;
    const clients = devices.map((device, index) => login(url, device, device.privateKey, signedCard(device, `Device ${index + 1}`)));
    assert.equal((await Promise.all(clients.map((client) => client.ready))).every(Boolean), true);
    for (const client of clients) {
      const frame = await waitForFrame(client, 'peers', (entry) => entry.online.length === 10 && entry.directory.length === 10);
      assert.equal(new Set(frame.directory.map((entry) => entry.id)).size, 10);
    }
  } finally {
    await relay.close();
  }
});

test('The whitelist distributes signed device cards, remembers offline peers and removes revoked identities', { timeout: 8000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'localsend-relay-directory-'));
  const directoryPath = join(directory, 'devices.json');
  const alice = identity();
  const bob = identity();
  const aliceCard = signedCard(alice, 'Alice');
  const bobCard = signedCard(bob, 'Bob');
  let relay = createRelay([alice.id, bob.id], { directoryPath });
  try {
    relay.server.listen(0, '127.0.0.1');
    await once(relay.server, 'listening');
    const url = `ws://127.0.0.1:${relay.server.address().port}/v1/relay`;
    const forged = { ...bobCard, card: bobCard.card.replace(Buffer.from('Bob').toString('base64url'), Buffer.from('Impostor').toString('base64url')) };
    assert.equal(await login(url, bob, bob.privateKey, forged).ready, false);
    const a = login(url, alice, alice.privateKey, aliceCard);
    const b = login(url, bob, bob.privateKey, bobCard);
    assert.deepEqual(await Promise.all([a.ready, b.ready]), [true, true]);
    const directoryFrame = await waitForFrame(a, 'peers', (frame) => frame.directory.length === 2);
    assert.equal(directoryFrame.directory.find((entry) => entry.id === bob.id).card, bobCard.card);
    b.socket.close();
    const offline = await waitForFrame(a, 'peers', (frame) => frame.directory.length === 2 && !frame.online.some((entry) => entry.id === bob.id));
    assert.equal(offline.directory.some((entry) => entry.id === bob.id), true);
    assert.equal(JSON.parse(await readFile(directoryPath, 'utf8')).length, 2);

    await relay.close();
    relay = createRelay([alice.id], { directoryPath });
    relay.server.listen(0, '127.0.0.1');
    await once(relay.server, 'listening');
    const updatedUrl = `ws://127.0.0.1:${relay.server.address().port}/v1/relay`;
    const resumed = login(updatedUrl, alice, alice.privateKey, aliceCard);
    assert.equal(await resumed.ready, true);
    const updated = await waitForFrame(resumed, 'peers', (frame) => frame.directory.length === 1);
    assert.equal(updated.directory[0].id, alice.id);
    assert.equal(await login(updatedUrl, bob, bob.privateKey, bobCard).ready, false);
  } finally {
    await relay.close();
    await rm(directory, { recursive: true, force: true });
  }
});

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

test('The relay pipelines chunks up to its advertised window and waits for every ACK', { timeout: 10000 }, async () => {
  const alice = identity();
  const bob = identity();
  const relay = createRelay([alice.id, bob.id]);
  try {
    relay.server.listen(0, '127.0.0.1');
    await once(relay.server, 'listening');
    const url = `ws://127.0.0.1:${relay.server.address().port}/v1/relay`;
    const receiver = login(url, bob);
    assert.equal(await receiver.ready, true);
    const control = randomBytes(28).toString('base64url');
    const chunk = randomBytes(256 * 1024 + 28).toString('base64url');
    for (const violation of [null, 'overflow', 'early finish', 'unsolicited ack']) {
      const sender = login(url, alice);
      assert.equal(await sender.ready, true);
      const { chunkWindow } = await waitForFrame(sender, 'ready', () => true);
      assert.equal(chunkWindow, 8);
      const session = randomBytes(16).toString('hex');
      const transmit = (client, type, seq, body = control, extra = {}) =>
        client.socket.send(JSON.stringify({ type, session, seq, body, ...extra }));

      transmit(sender, 'offer', 0, control, { to: bob.id, epoch: receiver.epoch });
      await waitForFrame(receiver, 'offer', (frame) => frame.session === session);
      transmit(receiver, 'accept', 0);
      await waitForFrame(sender, 'accept', (frame) => frame.session === session);

      if (violation === 'unsolicited ack') {
        const closed = once(receiver.socket, 'close');
        transmit(receiver, 'ack', 1);
        assert.equal((await closed)[0], 1008);
        await waitForFrame(sender, 'aborted', (frame) => frame.session === session);
        break;
      }

      for (let seq = 1; seq <= chunkWindow; seq++) transmit(sender, 'chunk', seq, chunk);
      await waitForFrame(receiver, 'chunk', (frame) => frame.session === session && frame.seq === chunkWindow);
      const chunks = receiver.messages.filter((frame) => frame.session === session && frame.type === 'chunk');
      assert.deepEqual(chunks.map((frame) => frame.seq), Array.from({ length: chunkWindow }, (_, index) => index + 1));

      if (violation) {
        const closed = once(sender.socket, 'close');
        if (violation === 'overflow') transmit(sender, 'chunk', chunkWindow + 1, chunk);
        else transmit(sender, 'finish', chunkWindow + 1);
        assert.equal((await closed)[0], 1008);
        await waitForFrame(receiver, 'aborted', (frame) => frame.session === session);
        continue;
      }

      for (let seq = 1; seq <= chunkWindow; seq++) transmit(receiver, 'ack', seq);
      await waitForFrame(sender, 'ack', (frame) => frame.seq === chunkWindow);
      transmit(sender, 'finish', chunkWindow + 1);
      await waitForFrame(receiver, 'finish', (frame) => frame.session === session);
      transmit(receiver, 'receipt', chunkWindow + 1);
      await waitForFrame(sender, 'receipt', (frame) => frame.session === session);
      const closed = once(sender.socket, 'close');
      sender.socket.close();
      await closed;
    }
  } finally {
    await relay.close();
  }
});

/**
 * Nostr challenge-response authentication for Brainstorm API.
 *
 * Flow:
 * 1. GET /authChallenge/{pubkey} → challenge string
 * 2. Sign a nostr event with tags: ["t", "brainstorm_login"], ["challenge", challenge]
 * 3. POST /authChallenge/{pubkey}/verify → JWT token
 */

import { finalizeEvent, getPublicKey } from 'nostr-tools/pure';
import { getClient } from './client.js';
import { loadConfig, saveConfig } from './config.js';

/**
 * Authenticate with the Brainstorm API using a nostr secret key.
 * @param {string} nsecOrHex - The nostr secret key (hex or nsec format)
 * @returns {Promise<string>} JWT token
 */
export async function authenticate(nsecOrHex) {
  const client = getClient();

  // Decode nsec if needed
  let secretKeyHex = nsecOrHex;
  if (nsecOrHex.startsWith('nsec')) {
    const { nip19 } = await import('nostr-tools/nip19');
    const decoded = nip19.decode(nsecOrHex);
    secretKeyHex = Buffer.from(decoded.data).toString('hex');
  }

  // Get pubkey from secret key
  const secretKeyBytes = Uint8Array.from(Buffer.from(secretKeyHex, 'hex'));
  const pubkey = getPublicKey(secretKeyBytes);

  // Step 1: Get challenge
  const challengeRes = await client.get(`/authChallenge/${pubkey}`);
  const challenge = challengeRes.data.challenge;

  // Step 2: Create and sign event
  const eventTemplate = {
    kind: 22242,
    created_at: Math.floor(Date.now() / 1000),
    tags: [
      ['t', 'brainstorm_login'],
      ['challenge', challenge],
    ],
    content: '',
  };

  const signedEvent = finalizeEvent(eventTemplate, secretKeyBytes);

  // Convert to the format the API expects
  const eventJson = {
    id: signedEvent.id,
    pubkey: signedEvent.pubkey,
    created_at: signedEvent.created_at,
    kind: signedEvent.kind,
    tags: signedEvent.tags,
    content: signedEvent.content,
    sig: signedEvent.sig,
  };

  // Step 3: Verify
  const verifyRes = await client.post(`/authChallenge/${pubkey}/verify`, {
    body: { signed_event: eventJson },
  });

  const token = verifyRes.data.token;

  // Save token to config
  const config = loadConfig();
  config.token = token;
  config.pubkey = pubkey;
  saveConfig(config);

  return { token, pubkey };
}

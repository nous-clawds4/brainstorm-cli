/**
 * brainstorm auth — Nostr challenge-response authentication.
 */

import { authenticate } from '../auth.js';
import { loadConfig } from '../config.js';
import { output, outputError } from '../output.js';

export function registerAuthCommand(program) {
  const auth = program
    .command('auth')
    .description('Authentication commands');

  auth
    .command('login')
    .description('Authenticate with a nostr secret key')
    .argument('<nsec-or-hex>', 'Nostr secret key (nsec1... or hex)')
    .action(async (nsecOrHex, opts) => {
      try {
        const { token, pubkey } = await authenticate(nsecOrHex);
        output({
          status: 'authenticated',
          pubkey,
          token,
        }, opts);
      } catch (err) {
        outputError('Authentication failed', err.message);
      }
    });

  auth
    .command('status')
    .description('Check current authentication status')
    .action(async (opts) => {
      const config = loadConfig();
      if (!config.token) {
        output({ status: 'not_authenticated', token: null });
        return;
      }

      // Try to decode JWT payload (it's base64, no verification needed)
      try {
        const parts = config.token.split('.');
        const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString());
        const expiresAt = payload.expires_date || payload.exp;
        const expired = expiresAt && new Date(expiresAt) < new Date();

        output({
          status: expired ? 'expired' : 'authenticated',
          pubkey: config.pubkey || payload.nostr_pubkey,
          expiresAt,
          expired,
        }, opts);
      } catch {
        output({
          status: 'has_token',
          pubkey: config.pubkey || null,
          note: 'Could not decode token payload',
        }, opts);
      }
    });
}

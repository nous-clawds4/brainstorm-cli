/**
 * brainstorm pubkey — Get/create Brainstorm observer keypair for a nostr pubkey.
 */

import { getClient } from '../client.js';
import { output, outputError } from '../output.js';

export function registerPubkeyCommand(program) {
  program
    .command('pubkey')
    .description('Get or create Brainstorm observer keypair for a nostr pubkey')
    .argument('<nostr-pubkey>', 'Nostr pubkey (hex)')
    .action(async (pubkey, opts) => {
      try {
        // Validate hex pubkey format
        if (!/^[0-9a-f]{64}$/i.test(pubkey)) {
          outputError('Invalid pubkey', 'Expected 64-character hex string');
        }

        const client = getClient();
        const result = await client.get(`/brainstormPubkey/${pubkey}`);

        output({
          globalPubkey: result.data.global_pubkey,
          brainstormPubkey: result.data.brainstorm_pubkey,
          triggeredGraperank: result.data.triggered_graperank ? {
            id: result.data.triggered_graperank.private_id,
            status: result.data.triggered_graperank.status,
            password: result.data.triggered_graperank.password,
          } : null,
          createdAt: result.data.created_at,
          updatedAt: result.data.updated_at,
        }, opts);
      } catch (err) {
        outputError('Failed to get/create observer', err.message);
      }
    });
}

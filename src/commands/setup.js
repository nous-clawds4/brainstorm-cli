/**
 * brainstorm setup — Get NIP-85 kind 10040 setup info for a nostr pubkey.
 *
 * Returns the tag data a client needs to construct a kind 10040 event
 * (WoT Service Provider configuration) for Brainstorm.
 */

import { getClient } from '../client.js';
import { output, outputError } from '../output.js';

export function registerSetupCommand(program) {
  program
    .command('setup')
    .description('Get NIP-85 (kind 10040) setup info for a nostr pubkey')
    .argument('<nostr-pubkey>', 'Nostr pubkey (hex)')
    .action(async (pubkey) => {
      try {
        if (!/^[0-9a-f]{64}$/i.test(pubkey)) {
          outputError('Invalid pubkey', 'Expected 64-character hex string');
        }

        const client = getClient();
        const result = await client.get(`/setup/${pubkey}`);

        // The endpoint returns a raw array (not wrapped in { data: ... })
        const tags = Array.isArray(result) ? result : result.data || result;

        output({
          pubkey,
          tags: tags.map(tag => ({
            descriptor: tag[0],    // e.g. "30382:rank"
            taPubkey: tag[1],      // Trusted Assertions pubkey
            relay: tag[2],         // relay URL
          })),
          raw10040Tags: tags,      // raw format for direct use in kind 10040 events
        });
      } catch (err) {
        outputError('Failed to get setup info', err.message);
      }
    });
}

/**
 * brainstorm health — Check if the Brainstorm server is reachable.
 */

import { getClient } from '../client.js';
import { output, outputError } from '../output.js';

export function registerHealthCommand(program) {
  program
    .command('health')
    .description('Check if the Brainstorm server is reachable')
    .action(async (opts) => {
      try {
        const client = getClient();
        const start = Date.now();
        const result = await client.get('/health');
        const elapsed = Date.now() - start;

        output({
          status: 'ok',
          server: client.serverUrl,
          response: result,
          latencyMs: elapsed,
        }, opts.parent?.opts?.() || {});
      } catch (err) {
        outputError('Server unreachable', err.message);
      }
    });
}

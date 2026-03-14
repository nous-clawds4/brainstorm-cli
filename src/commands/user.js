/**
 * brainstorm user — User graph data and GrapeRank operations (auth required).
 */

import { getClient } from '../client.js';
import { output, outputError } from '../output.js';

export function registerUserCommand(program) {
  const user = program
    .command('user')
    .description('User graph data and GrapeRank operations (auth required)');

  user
    .command('self')
    .description('Get your own social graph and history')
    .action(async (opts) => {
      try {
        const client = getClient();
        const result = await client.get('/user/self', { auth: true });

        const graph = result.data.graph;
        output({
          influence: graph.influence,
          followedBy: graph.followed_by.length,
          following: graph.following.length,
          mutedBy: graph.muted_by.length,
          muting: graph.muting.length,
          reportedBy: graph.reported_by.length,
          reporting: graph.reporting.length,
          topFollowers: graph.followed_by
            .sort((a, b) => (b.influence || 0) - (a.influence || 0))
            .slice(0, 10)
            .map(f => ({ pubkey: f.pubkey, influence: f.influence })),
          history: {
            pubkey: result.data.history.pubkey,
            taPubkey: result.data.history.ta_pubkey,
            lastCalculated: result.data.history.last_time_calculated_graperank,
            lastTriggered: result.data.history.last_time_triggered_graperank,
          },
        }, opts);
      } catch (err) {
        outputError('Failed to get user data (are you authenticated?)', err.message);
      }
    });

  user
    .command('lookup')
    .description("Get another user's social graph from your perspective")
    .argument('<pubkey>', 'Nostr pubkey (hex)')
    .action(async (pubkey, opts) => {
      try {
        if (!/^[0-9a-f]{64}$/i.test(pubkey)) {
          outputError('Invalid pubkey', 'Expected 64-character hex string');
        }

        const client = getClient();
        const result = await client.get(`/user/${pubkey}`, { auth: true });

        const graph = result.data;
        output({
          pubkey,
          influence: graph.influence,
          followedBy: graph.followed_by.length,
          following: graph.following.length,
          mutedBy: graph.muted_by.length,
          muting: graph.muting.length,
          reportedBy: graph.reported_by.length,
          reporting: graph.reporting.length,
          topFollowers: graph.followed_by
            .sort((a, b) => (b.influence || 0) - (a.influence || 0))
            .slice(0, 10)
            .map(f => ({ pubkey: f.pubkey, influence: f.influence })),
        }, opts);
      } catch (err) {
        outputError('Failed to get user data', err.message);
      }
    });

  user
    .command('graperank')
    .description('Get latest GrapeRank result or trigger a new calculation')
    .option('--trigger', 'Trigger a new GrapeRank calculation')
    .action(async (opts) => {
      try {
        const client = getClient();

        if (opts.trigger) {
          const result = await client.post('/user/graperank', { auth: true });
          output({
            action: 'triggered',
            id: result.data?.private_id,
            status: result.data?.status,
            password: result.data?.password,
          }, opts);
        } else {
          const result = await client.get('/user/graperankResult', { auth: true });
          if (!result.data) {
            output({ status: 'no_results', data: null }, opts);
          } else {
            output({
              id: result.data.private_id,
              status: result.data.status,
              taStatus: result.data.ta_status,
              internalPublicationStatus: result.data.internal_publication_status,
              algorithm: result.data.algorithm,
              createdAt: result.data.created_at,
              updatedAt: result.data.updated_at,
            }, opts);
          }
        }
      } catch (err) {
        outputError('GrapeRank operation failed', err.message);
      }
    });
}

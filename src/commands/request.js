/**
 * brainstorm request — Create and poll computation requests.
 */

import { getClient } from '../client.js';
import { output, outputError } from '../output.js';

export function registerRequestCommand(program) {
  const req = program
    .command('request')
    .description('Manage computation requests');

  req
    .command('create')
    .description('Submit a new computation request')
    .argument('<algorithm>', 'Algorithm name (e.g., "graperank")')
    .argument('<parameters>', 'Algorithm parameters (e.g., observer pubkey)')
    .argument('<pubkey>', 'Requesting pubkey')
    .action(async (algorithm, parameters, pubkey, opts) => {
      try {
        const client = getClient();
        const result = await client.post('/brainstormRequest/', {
          body: { algorithm, parameters, pubkey },
        });

        output({
          id: result.data.private_id,
          status: result.data.status,
          password: result.data.password,
          algorithm: result.data.algorithm,
          parameters: result.data.parameters,
          queuePosition: result.data.how_many_others_with_priority,
          createdAt: result.data.created_at,
        }, opts);
      } catch (err) {
        outputError('Failed to create request', err.message);
      }
    });

  req
    .command('status')
    .description('Check the status of a computation request')
    .argument('<id>', 'Request ID')
    .argument('<password>', 'Request password')
    .action(async (id, password, opts) => {
      try {
        const client = getClient();
        const result = await client.get(`/brainstormRequest/${id}`, {
          query: {
            brainstorm_request_password: password,
            include_result: false,
          },
        });

        output({
          id: result.data.private_id,
          status: result.data.status,
          taStatus: result.data.ta_status,
          internalPublicationStatus: result.data.internal_publication_status,
          countValues: result.data.count_values ? JSON.parse(result.data.count_values) : null,
          queuePosition: result.data.how_many_others_with_priority,
          createdAt: result.data.created_at,
          updatedAt: result.data.updated_at,
        }, opts);
      } catch (err) {
        outputError('Failed to get request status', err.message);
      }
    });

  req
    .command('result')
    .description('Get the full result of a computation request')
    .argument('<id>', 'Request ID')
    .argument('<password>', 'Request password')
    .action(async (id, password, opts) => {
      try {
        const client = getClient();
        const result = await client.get(`/brainstormRequest/${id}`, {
          query: {
            brainstorm_request_password: password,
            include_result: true,
          },
        });

        const data = {
          id: result.data.private_id,
          status: result.data.status,
          taStatus: result.data.ta_status,
          internalPublicationStatus: result.data.internal_publication_status,
        };

        if (result.data.result) {
          try {
            data.result = JSON.parse(result.data.result);
          } catch {
            data.result = result.data.result;
          }
        } else {
          data.result = null;
        }

        if (result.data.count_values) {
          try {
            data.countValues = JSON.parse(result.data.count_values);
          } catch {
            data.countValues = result.data.count_values;
          }
        }

        output(data, opts);
      } catch (err) {
        outputError('Failed to get request result', err.message);
      }
    });
}

/**
 * brainstorm test — Run test suites against the Brainstorm server.
 *
 * Tests are designed to validate the full pipeline:
 * connectivity, authentication, observer creation, GrapeRank, and graph integrity.
 */

import { getClient } from '../client.js';
import { loadConfig } from '../config.js';
import { output, outputError } from '../output.js';

// Test result tracking
function createRunner() {
  const results = [];

  async function run(name, fn) {
    const start = Date.now();
    try {
      await fn();
      results.push({ name, status: 'PASS', elapsed: Date.now() - start });
    } catch (err) {
      results.push({ name, status: 'FAIL', error: err.message, elapsed: Date.now() - start });
    }
  }

  function summary() {
    const passed = results.filter(r => r.status === 'PASS').length;
    const failed = results.filter(r => r.status === 'FAIL').length;
    return { total: results.length, passed, failed, tests: results };
  }

  return { run, summary };
}

// ── Smoke Tests ──

async function runSmokeTests(runner) {
  const client = getClient();

  await runner.run('health: server reachable', async () => {
    const result = await client.get('/health');
    if (result !== 1) throw new Error(`Expected 1, got ${JSON.stringify(result)}`);
  });

  await runner.run('health: response time < 5s', async () => {
    const start = Date.now();
    await client.get('/health');
    const elapsed = Date.now() - start;
    if (elapsed > 5000) throw new Error(`Response took ${elapsed}ms`);
  });
}

// ── Auth Tests ──

async function runAuthTests(runner) {
  const client = getClient();
  const config = loadConfig();

  await runner.run('auth: challenge endpoint returns challenge', async () => {
    // Use a test pubkey (all zeros — won't match a real user, but tests the endpoint)
    const testPubkey = '0'.repeat(64);
    const result = await client.get(`/authChallenge/${testPubkey}`);
    if (!result?.data?.challenge) throw new Error('No challenge in response');
    if (typeof result.data.challenge !== 'string') throw new Error('Challenge is not a string');
    if (result.data.challenge.length !== 32) throw new Error(`Challenge length ${result.data.challenge.length}, expected 32`);
  });

  await runner.run('auth: has saved token', async () => {
    if (!config.token) throw new Error('No token in config. Run: brainstorm auth login <nsec>');
  });

  if (config.token) {
    await runner.run('auth: token accepted on /user/self', async () => {
      // This will fail if token is expired or invalid
      await client.get('/user/self', { auth: true });
    });
  }
}

// ── Observer Tests ──

async function runObserverTests(runner) {
  const client = getClient();
  const config = loadConfig();

  if (!config.pubkey) {
    await runner.run('observer: pubkey configured', async () => {
      throw new Error('No pubkey in config. Run: brainstorm auth login <nsec>');
    });
    return;
  }

  await runner.run('observer: get observer keypair', async () => {
    const result = await client.get(`/brainstormPubkey/${config.pubkey}`);
    if (!result?.data?.brainstorm_pubkey) throw new Error('No brainstorm_pubkey in response');
    if (!result?.data?.global_pubkey) throw new Error('No global_pubkey in response');
    if (result.data.global_pubkey !== config.pubkey) {
      throw new Error(`Pubkey mismatch: ${result.data.global_pubkey} vs ${config.pubkey}`);
    }
  });
}

// ── GrapeRank Tests ──

async function runGrapeRankTests(runner) {
  const client = getClient();
  const config = loadConfig();

  if (!config.token) {
    await runner.run('graperank: auth required', async () => {
      throw new Error('No token. Run: brainstorm auth login <nsec>');
    });
    return;
  }

  await runner.run('graperank: get latest result', async () => {
    const result = await client.get('/user/graperankResult', { auth: true });
    // null is acceptable (no calculation yet), but the endpoint should work
    if (result.code !== 200) throw new Error(`Unexpected response code: ${result.code}`);
  });

  await runner.run('graperank: get user graph', async () => {
    const result = await client.get('/user/self', { auth: true });
    const graph = result.data.graph;
    if (!Array.isArray(graph.followed_by)) throw new Error('followed_by not an array');
    if (!Array.isArray(graph.following)) throw new Error('following not an array');
    if (!Array.isArray(graph.muted_by)) throw new Error('muted_by not an array');
    if (!Array.isArray(graph.muting)) throw new Error('muting not an array');
    if (!Array.isArray(graph.reported_by)) throw new Error('reported_by not an array');
    if (!Array.isArray(graph.reporting)) throw new Error('reporting not an array');
  });
}

// ── Test Command Registration ──

export function registerTestCommand(program) {
  const test = program
    .command('test')
    .description('Run test suites against the Brainstorm server');

  test
    .command('smoke')
    .description('Basic connectivity tests')
    .action(async (opts) => {
      const runner = createRunner();
      await runSmokeTests(runner);
      output(runner.summary());
      if (runner.summary().failed > 0) process.exit(1);
    });

  test
    .command('auth')
    .description('Authentication flow tests')
    .action(async (opts) => {
      const runner = createRunner();
      await runAuthTests(runner);
      output(runner.summary());
      if (runner.summary().failed > 0) process.exit(1);
    });

  test
    .command('observer')
    .description('Observer keypair tests')
    .action(async (opts) => {
      const runner = createRunner();
      await runObserverTests(runner);
      output(runner.summary());
      if (runner.summary().failed > 0) process.exit(1);
    });

  test
    .command('graperank')
    .description('GrapeRank pipeline tests')
    .action(async (opts) => {
      const runner = createRunner();
      await runGrapeRankTests(runner);
      output(runner.summary());
      if (runner.summary().failed > 0) process.exit(1);
    });

  test
    .command('all')
    .description('Run all test suites')
    .action(async (opts) => {
      const runner = createRunner();
      await runSmokeTests(runner);
      await runAuthTests(runner);
      await runObserverTests(runner);
      await runGrapeRankTests(runner);
      output(runner.summary());
      if (runner.summary().failed > 0) process.exit(1);
    });
}

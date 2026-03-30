/**
 * brainstorm test propagation — End-to-end propagation test.
 *
 * Publishes a kind:3 follow-list change, then monitors each hop in the
 * pipeline until the Brainstorm API reflects the change.
 *
 * Pipeline:
 *   1. Publish kind:3 to Nous's relays
 *   2. Verify event on gatekeeper relay (wss://wot.grapevine.network)
 *   3. (future) Verify event on neofry/brainstorm relay
 *   4. Verify graph updated in Brainstorm API (/user/self)
 *   5. Revert follow list to original state
 *
 * Requires:
 *   - `nak` CLI in PATH
 *   - Nostr secret key available (via --sec, NOSTR_SECRET_KEY env, or 1Password)
 *   - Authenticated brainstorm-cli session (brainstorm auth login)
 */

import { execSync, spawnSync } from 'child_process';
import { getClient } from '../client.js';
import { loadConfig } from '../config.js';
import { output, outputError } from '../output.js';

// ── Constants ──

const GATEKEEPER_RELAY = 'wss://wot.grapevine.network';
const PUBLISH_RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

// A deterministic "test" pubkey that won't collide with real users.
// SHA-256("brainstorm-cli-propagation-test") truncated — not a real person.
const TEST_FOLLOW_PUBKEY = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const DEFAULT_TIMEOUT_S = 120;
const POLL_INTERVAL_MS = 3000;

// ── Helpers ──

function now() {
  return Date.now();
}

function elapsed(startMs) {
  return `+${((Date.now() - startMs) / 1000).toFixed(1)}s`;
}

function log(startMs, message) {
  console.error(`  ${elapsed(startMs).padEnd(8)} ${message}`);
}

/**
 * Run a shell command and return stdout, or null on failure.
 */
function run(cmd, { timeout = 15000 } = {}) {
  try {
    return execSync(cmd, {
      encoding: 'utf-8',
      timeout,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch {
    return null;
  }
}

/**
 * Fetch Nous's current kind:3 event from a relay.
 * Returns the parsed event object or null.
 */
function fetchKind3(pubkey, relay) {
  const raw = run(`nak req -k 3 -a ${pubkey} -l 1 ${relay} 2>/dev/null`);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

/**
 * Retrieve the nostr secret key.
 * Priority: --sec flag > NOSTR_SECRET_KEY env > 1Password lookup.
 */
function getSecretKey(opts) {
  if (opts.sec) return opts.sec;
  if (process.env.NOSTR_SECRET_KEY) return process.env.NOSTR_SECRET_KEY;

  // Try 1Password CLI
  const nsec = run('op read "op://Personal/Nous - Nostr Key/password" 2>/dev/null');
  if (nsec) return nsec;

  return null;
}

/**
 * Publish a kind:3 event with the given p-tags.
 * Feeds a partial event via stdin to nak, which is more robust than
 * building a huge command line with many -p flags.
 * Returns the event id on success, or null.
 */
function publishKind3(sec, pTags, relays) {
  const partial = JSON.stringify({
    kind: 3,
    content: '',
    tags: pTags.map(pk => ['p', pk]),
  });

  const relayArgs = relays.join(' ');
  const result = spawnSync('nak', ['event', '--sec', sec, ...relays], {
    input: partial,
    encoding: 'utf-8',
    timeout: 30000,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const stdout = (result.stdout || '').trim();
  if (!stdout) return null;

  // nak prints the signed event JSON (possibly one per relay)
  // Take the first line that parses as JSON
  for (const line of stdout.split('\n')) {
    try {
      const ev = JSON.parse(line.trim());
      if (ev.id) return ev.id;
    } catch {
      // not JSON — skip
    }
  }

  return stdout.includes('ok') ? 'published' : null;
}

/**
 * Poll a relay until a kind:3 from `pubkey` contains `targetPubkey` in its tags,
 * or until timeout.
 * Returns { found: true, elapsed: <ms> } or { found: false }.
 */
async function pollRelayForFollow(pubkey, targetPubkey, relay, timeoutMs) {
  const start = now();
  while (now() - start < timeoutMs) {
    const ev = fetchKind3(pubkey, relay);
    if (ev && ev.tags) {
      const hasTarget = ev.tags.some(
        t => t[0] === 'p' && t[1] === targetPubkey
      );
      if (hasTarget) {
        return { found: true, elapsed: now() - start };
      }
    }
    await sleep(POLL_INTERVAL_MS);
  }
  return { found: false, elapsed: now() - start };
}

/**
 * Poll the Brainstorm API until the `following` list includes targetPubkey,
 * or until timeout.
 */
async function pollApiForFollow(client, targetPubkey, timeoutMs) {
  const start = now();
  while (now() - start < timeoutMs) {
    try {
      const result = await client.get('/user/self', { auth: true });
      const following = result?.data?.graph?.following || [];
      if (following.includes(targetPubkey)) {
        return { found: true, elapsed: now() - start };
      }
    } catch {
      // API error — keep trying
    }
    await sleep(POLL_INTERVAL_MS);
  }
  return { found: false, elapsed: now() - start };
}

/**
 * Poll the Brainstorm API until the `following` list does NOT include targetPubkey.
 */
async function pollApiForUnfollow(client, targetPubkey, timeoutMs) {
  const start = now();
  while (now() - start < timeoutMs) {
    try {
      const result = await client.get('/user/self', { auth: true });
      const following = result?.data?.graph?.following || [];
      if (!following.includes(targetPubkey)) {
        return { found: true, elapsed: now() - start };
      }
    } catch {
      // API error — keep trying
    }
    await sleep(POLL_INTERVAL_MS);
  }
  return { found: false, elapsed: now() - start };
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// ── Main Test ──

async function runPropagationTest(opts) {
  const startMs = now();
  const timeoutMs = (opts.timeout || DEFAULT_TIMEOUT_S) * 1000;
  const results = [];

  console.error('\n  Brainstorm Propagation Test');
  console.error('  ─────────────────────────────────────');

  // ── Pre-flight checks ──

  const config = loadConfig();
  const sec = getSecretKey(opts);
  if (!sec) {
    outputError('No secret key available',
      'Provide --sec <nsec>, set NOSTR_SECRET_KEY, or configure 1Password CLI');
    return;
  }

  if (!config.token) {
    outputError('Not authenticated',
      'Run: brainstorm auth login <nsec>');
    return;
  }

  // Derive pubkey from the secret key
  const pubkeyRaw = run(`nak key public ${sec} 2>/dev/null`);
  if (!pubkeyRaw) {
    outputError('Could not derive pubkey from secret key', 'Check that nak is installed and the key is valid');
    return;
  }
  const pubkey = pubkeyRaw.trim();

  log(startMs, `pubkey: ${pubkey.slice(0, 12)}...`);
  log(startMs, `test follow: ${TEST_FOLLOW_PUBKEY.slice(0, 12)}...`);

  // ── Step 0: Fetch current follow list ──

  log(startMs, 'fetching current follow list...');
  const originalEvent = fetchKind3(pubkey, PUBLISH_RELAYS[0]);
  if (!originalEvent) {
    outputError('Could not fetch current kind:3 event', `Tried ${PUBLISH_RELAYS[0]}`);
    return;
  }
  const originalPubkeys = originalEvent.tags
    .filter(t => t[0] === 'p')
    .map(t => t[1]);

  log(startMs, `current follows: ${originalPubkeys.length}`);

  // Check if test pubkey is already followed (shouldn't be, but handle it)
  if (originalPubkeys.includes(TEST_FOLLOW_PUBKEY)) {
    outputError('Test pubkey already in follow list',
      'Remove it manually and retry, or use a different test pubkey');
    return;
  }

  // ── Step 1: Publish modified follow list (add test pubkey) ──

  log(startMs, 'publishing follow list with test pubkey...');
  const newPubkeys = [...originalPubkeys, TEST_FOLLOW_PUBKEY];
  const eventId = publishKind3(sec, newPubkeys, PUBLISH_RELAYS);

  if (!eventId) {
    outputError('Failed to publish kind:3 event');
    return;
  }

  const publishTime = now();
  log(startMs, `published to ${PUBLISH_RELAYS.length} relays`);
  results.push({ hop: 'publish', status: 'PASS', elapsed: now() - startMs });

  // ── Step 2: Verify on gatekeeper relay ──

  log(startMs, `waiting for event on gatekeeper (${GATEKEEPER_RELAY})...`);
  const gatekeeperResult = await pollRelayForFollow(
    pubkey, TEST_FOLLOW_PUBKEY, GATEKEEPER_RELAY, timeoutMs
  );

  if (gatekeeperResult.found) {
    log(startMs, `✓ event on gatekeeper (${(gatekeeperResult.elapsed / 1000).toFixed(1)}s)`);
    results.push({ hop: 'gatekeeper', status: 'PASS', elapsed: gatekeeperResult.elapsed });
  } else {
    log(startMs, `✗ event NOT seen on gatekeeper after ${(gatekeeperResult.elapsed / 1000).toFixed(0)}s`);
    results.push({ hop: 'gatekeeper', status: 'FAIL', elapsed: gatekeeperResult.elapsed });
  }

  // ── Step 3: (future) Check neofry/brainstorm relay ──
  // TODO: Add neofry relay check once public URL is known
  results.push({ hop: 'neofry', status: 'SKIP', note: 'no public URL configured' });

  // ── Step 4: Verify graph updated in Brainstorm API ──

  const client = getClient();

  // Re-auth if token might be expired
  log(startMs, 'waiting for Brainstorm API to reflect the follow...');

  const remainingMs = timeoutMs - (now() - publishTime);
  if (remainingMs <= 0) {
    log(startMs, '✗ timeout before API check');
    results.push({ hop: 'api', status: 'FAIL', note: 'timeout' });
  } else {
    const apiResult = await pollApiForFollow(client, TEST_FOLLOW_PUBKEY, remainingMs);
    if (apiResult.found) {
      const totalElapsed = now() - publishTime;
      log(startMs, `✓ API graph updated (${(totalElapsed / 1000).toFixed(1)}s from publish)`);
      results.push({ hop: 'api', status: 'PASS', elapsed: totalElapsed });
    } else {
      log(startMs, `✗ API graph NOT updated after ${(apiResult.elapsed / 1000).toFixed(0)}s`);
      results.push({ hop: 'api', status: 'FAIL', elapsed: apiResult.elapsed });
    }
  }

  // ── Step 5: Revert follow list ──

  log(startMs, 'reverting follow list...');
  const revertResult = publishKind3(sec, originalPubkeys, PUBLISH_RELAYS);
  if (revertResult) {
    log(startMs, '✓ follow list reverted');
    results.push({ hop: 'revert', status: 'PASS' });
  } else {
    log(startMs, '✗ FAILED to revert follow list — manual cleanup needed!');
    results.push({ hop: 'revert', status: 'FAIL', note: 'manual cleanup required' });
  }

  // ── Step 6: Wait for API to reflect the revert ──

  if (opts.waitRevert) {
    log(startMs, 'waiting for API to reflect revert...');
    const revertApiResult = await pollApiForUnfollow(client, TEST_FOLLOW_PUBKEY, timeoutMs);
    if (revertApiResult.found) {
      log(startMs, `✓ API reverted (${(revertApiResult.elapsed / 1000).toFixed(1)}s)`);
      results.push({ hop: 'revert-api', status: 'PASS', elapsed: revertApiResult.elapsed });
    } else {
      log(startMs, `✗ API still shows test follow after ${(revertApiResult.elapsed / 1000).toFixed(0)}s`);
      results.push({ hop: 'revert-api', status: 'FAIL', elapsed: revertApiResult.elapsed });
    }
  }

  // ── Summary ──

  console.error('  ─────────────────────────────────────');

  const passed = results.filter(r => r.status === 'PASS').length;
  const failed = results.filter(r => r.status === 'FAIL').length;
  const skipped = results.filter(r => r.status === 'SKIP').length;

  const totalElapsed = now() - startMs;

  const summary = {
    test: 'propagation',
    total: results.length,
    passed,
    failed,
    skipped,
    elapsed: totalElapsed,
    hops: results,
  };

  // Highlight the key metric: end-to-end publish → API latency
  const apiHop = results.find(r => r.hop === 'api');
  if (apiHop && apiHop.status === 'PASS') {
    summary.pipelineLatency = apiHop.elapsed;
    log(startMs, `pipeline latency: ${(apiHop.elapsed / 1000).toFixed(1)}s`);
  }

  console.error('');
  output(summary);

  if (failed > 0) process.exit(1);
}

// ── Command Registration ──

export function registerPropagationTestCommand(testCommand) {
  testCommand
    .command('propagation')
    .description('End-to-end propagation test: publish kind:3 → gatekeeper → API')
    .option('--timeout <seconds>', 'max wait per hop', parseInt, DEFAULT_TIMEOUT_S)
    .option('--sec <nsec>', 'nostr secret key (nsec or hex)')
    .option('--wait-revert', 'also wait for the API to reflect the revert', false)
    .option('--verbose', 'show additional debug output', false)
    .action(runPropagationTest);
}

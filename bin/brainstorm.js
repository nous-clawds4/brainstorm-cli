#!/usr/bin/env node

/**
 * Brainstorm CLI — Agent interface to the Brainstorm backend.
 *
 * Brainstorm-UI for humans, Brainstorm-CLI for agents.
 */

import { Command } from 'commander';
import { configure } from '../src/output.js';
import { registerHealthCommand } from '../src/commands/health.js';
import { registerAuthCommand } from '../src/commands/auth.js';
import { registerPubkeyCommand } from '../src/commands/pubkey.js';
import { registerRequestCommand } from '../src/commands/request.js';
import { registerUserCommand } from '../src/commands/user.js';
import { registerConfigCommand } from '../src/commands/config.js';
import { registerSetupCommand } from '../src/commands/setup.js';
import { registerTestCommand } from '../src/commands/test.js';

const program = new Command();

program
  .name('brainstorm')
  .description('CLI for LLM agents to interact with the Brainstorm backend')
  .version('0.1.0')
  .option('--pretty', 'Pretty-print JSON output')
  .hook('preAction', () => {
    configure(program.opts());
  });

// Register all command groups
registerHealthCommand(program);
registerAuthCommand(program);
registerPubkeyCommand(program);
registerRequestCommand(program);
registerUserCommand(program);
registerSetupCommand(program);
registerConfigCommand(program);
registerTestCommand(program);

program.parse();

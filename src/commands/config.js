/**
 * brainstorm config — View and modify CLI configuration.
 */

import { loadConfig, saveConfig } from '../config.js';
import { output } from '../output.js';

export function registerConfigCommand(program) {
  const config = program
    .command('config')
    .description('View and modify CLI configuration');

  config
    .command('show')
    .description('Show current configuration')
    .action(async (opts) => {
      const cfg = loadConfig();
      // Mask the token for display
      const display = { ...cfg };
      if (display.token) {
        display.token = display.token.slice(0, 20) + '...';
      }
      output(display);
    });

  config
    .command('set')
    .description('Set a configuration value')
    .argument('<key>', 'Config key (server-url, token)')
    .argument('<value>', 'Config value')
    .action(async (key, value, opts) => {
      const cfg = loadConfig();

      const keyMap = {
        'server-url': 'serverUrl',
        'serverUrl': 'serverUrl',
        'token': 'token',
        'pubkey': 'pubkey',
      };

      const configKey = keyMap[key];
      if (!configKey) {
        console.error(JSON.stringify({ error: `Unknown config key: ${key}`, validKeys: Object.keys(keyMap) }));
        process.exit(1);
      }

      cfg[configKey] = value;
      saveConfig(cfg);
      output({ status: 'updated', key: configKey, value: configKey === 'token' ? '***' : value });
    });

  config
    .command('reset')
    .description('Reset configuration to defaults')
    .action(async (opts) => {
      saveConfig({
        serverUrl: 'http://localhost:8000',
        token: null,
      });
      output({ status: 'reset' });
    });
}

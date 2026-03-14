/**
 * Configuration management for brainstorm-cli.
 * Stores server URL and auth token in ~/.brainstorm-cli/config.json
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const CONFIG_DIR = join(homedir(), '.brainstorm-cli');
const CONFIG_FILE = join(CONFIG_DIR, 'config.json');

const DEFAULTS = {
  serverUrl: 'http://localhost:8000',
  token: null,
};

function ensureConfigDir() {
  if (!existsSync(CONFIG_DIR)) {
    mkdirSync(CONFIG_DIR, { recursive: true });
  }
}

export function loadConfig() {
  ensureConfigDir();
  if (!existsSync(CONFIG_FILE)) {
    return { ...DEFAULTS };
  }
  try {
    const raw = readFileSync(CONFIG_FILE, 'utf-8');
    return { ...DEFAULTS, ...JSON.parse(raw) };
  } catch {
    return { ...DEFAULTS };
  }
}

export function saveConfig(config) {
  ensureConfigDir();
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2) + '\n');
}

export function getServerUrl() {
  return loadConfig().serverUrl;
}

export function getToken() {
  return loadConfig().token;
}

/**
 * Persistent config file support for Agent-OS CLI.
 * Stores config in ~/.agent-os/config.json.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CONFIG_DIR = join(homedir(), '.agent-os');
const CONFIG_FILE = join(CONFIG_DIR, 'config.json');

export function load() {
  try {
    return JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
  } catch {
    return {};
  }
}

export function save(config) {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
}

export function get(key) {
  return load()[key];
}

export function set(key, value) {
  const config = load();
  config[key] = value;
  save(config);
}

// Exported for testing
export { CONFIG_DIR, CONFIG_FILE };

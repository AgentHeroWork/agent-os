/**
 * Auth commands — login, logout.
 */

import * as config from '../config.js';
import * as out from '../output.js';
import { createInterface } from 'node:readline';

/**
 * Prompt the user for an API key via stdin.
 * @returns {Promise<string>} The entered API key
 */
function promptForKey() {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question('API key: ', (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

/**
 * Login — store API key and host in config.
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function login(args, opts) {
  const apiKey = opts.apiKey || await promptForKey();
  if (!apiKey) {
    out.error('API key is required. Pass --api-key <key> or enter interactively.');
    process.exit(1);
  }
  config.set('apiKey', apiKey);
  if (opts.host && opts.host !== 'http://localhost:4000') {
    config.set('host', opts.host);
  }
  out.success('Logged in. Config saved to ~/.agent-os/config.json');
}

/**
 * Logout — clear stored API key.
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function logout(args, opts) {
  config.set('apiKey', null);
  out.success('Logged out.');
}

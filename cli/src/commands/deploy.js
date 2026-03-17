/**
 * Deploy commands — docker, fly.
 */

import { execFileSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as http from '../http.js';
import * as out from '../output.js';

/** Resolve the repo root (cli/ is one level deep in agent-os). */
function repoRoot() {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  return resolve(__dirname, '..', '..');
}

/**
 * Run a command safely using execFileSync (no shell injection).
 * @param {string} cmd - Command name
 * @param {string[]} cmdArgs - Command arguments
 * @param {string} cwd - Working directory
 */
function run(cmd, cmdArgs, cwd) {
  out.info(`> ${cmd} ${cmdArgs.join(' ')}`);
  execFileSync(cmd, cmdArgs, { cwd, stdio: 'inherit' });
}

/**
 * Deploy with Docker.
 * Builds the image and starts containers, then checks health.
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function docker(args, opts) {
  const root = repoRoot();

  out.info('Building Docker image...');
  run('docker', ['build', '-t', 'agent-os', '.'], root);

  out.info('Starting containers...');
  run('docker-compose', ['up', '-d'], root);

  out.info('Checking health...');
  try {
    const result = await http.get('/api/v1/health', opts);
    out.success('Agent-OS is running (Docker).');
    out.json(result);
  } catch (e) {
    out.error(`Health check failed: ${e.message}`);
    out.info('Containers may still be starting. Try: agent-os health');
    process.exit(1);
  }
}

/**
 * Deploy to Fly.io.
 * Runs fly deploy with optional --region and --app flags, then checks health.
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function fly(args, opts) {
  const root = repoRoot();
  const region = opts.region || 'iad';
  const app = opts.app || 'agent-os';

  out.info(`Deploying to Fly.io (app=${app}, region=${region})...`);
  run('fly', ['deploy', '--region', region, '--app', app], root);

  const flyHost = `https://${app}.fly.dev`;
  out.info(`Checking health at ${flyHost}...`);
  try {
    const result = await http.get('/api/v1/health', { ...opts, host: flyHost });
    out.success(`Agent-OS is running on Fly.io (${flyHost}).`);
    out.json(result);
  } catch (e) {
    out.error(`Health check failed: ${e.message}`);
    out.info('Deployment may still be in progress. Try: agent-os health');
    process.exit(1);
  }
}

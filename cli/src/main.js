/**
 * Agent-OS CLI — main entry point.
 * Parses argv, resolves global options, and routes to command handlers.
 */

import { parseArgs } from 'node:util';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import * as agentCmd from './commands/agent.js';
import * as jobCmd from './commands/job.js';
import * as memoryCmd from './commands/memory.js';
import * as deployCmd from './commands/deploy.js';
import * as http from './http.js';
import * as out from './output.js';

const HELP = `
agent-os — manage AI agents locally or in the cloud

USAGE
  agent-os <command> <subcommand> [options]

COMMANDS
  agent create    Create an agent        --type <type> --name <name> [--oversight <level>]
  agent list      List agents
  agent start     Start an agent         <id> --job '<json>'
  agent stop      Stop an agent          <id>
  agent logs      Get agent logs         <id> [--follow]

  job submit      Submit a job           --task <task> --input '<json>'
  job status      Get job status         <id>

  memory search   Search memory          "<query>"
  memory show     Show memory entry      <id>

  deploy docker   Deploy with Docker
  deploy fly      Deploy to Fly.io       [--region <region>] [--app <name>]

  health          Check API health
  version         Print CLI version

GLOBAL OPTIONS
  --target <local|fly>   Target environment (default: local, or AGENT_OS_TARGET)
  --host <url>           API host (default: http://localhost:4000, or AGENT_OS_HOST)
  --api-key <key>        API key (or AGENT_OS_API_KEY)
  --json                 Output as JSON
  --help                 Show this help
`.trim();

/**
 * Read package.json version.
 * @returns {string} Version string
 */
function getVersion() {
  try {
    const __dirname = dirname(fileURLToPath(import.meta.url));
    const pkg = JSON.parse(readFileSync(resolve(__dirname, '..', 'package.json'), 'utf-8'));
    return pkg.version;
  } catch {
    return '0.0.0';
  }
}

/**
 * Parse global options and extract the command/subcommand/positional args.
 * @param {string[]} argv - Raw process.argv.slice(2)
 * @returns {{ command: string, subcommand: string, args: string[], opts: object }}
 */
export function parseGlobalArgs(argv) {
  // We need to pull out known global flags while leaving the rest as positional.
  // Use parseArgs with allowPositionals and strict: false to be forgiving.
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      target: { type: 'string', short: 't' },
      host: { type: 'string' },
      'api-key': { type: 'string' },
      json: { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h', default: false },
      // Command-specific flags we need to capture
      type: { type: 'string' },
      name: { type: 'string' },
      oversight: { type: 'string' },
      job: { type: 'string' },
      task: { type: 'string' },
      input: { type: 'string' },
      follow: { type: 'boolean', short: 'f', default: false },
      region: { type: 'string' },
      app: { type: 'string' },
    },
    allowPositionals: true,
    strict: false,
  });

  const command = positionals[0] || '';
  const subcommand = positionals[1] || '';
  const args = positionals.slice(2);

  const opts = {
    target: values.target || process.env.AGENT_OS_TARGET || 'local',
    host: values.host || process.env.AGENT_OS_HOST || 'http://localhost:4000',
    apiKey: values['api-key'] || process.env.AGENT_OS_API_KEY || undefined,
    json: values.json,
    help: values.help,
    // Command-specific
    type: values.type,
    name: values.name,
    oversight: values.oversight,
    job: values.job,
    task: values.task,
    input: values.input,
    follow: values.follow,
    region: values.region,
    app: values.app,
  };

  return { command, subcommand, args, opts };
}

/**
 * Route commands to the appropriate handler.
 * @param {string[]} argv - Raw process.argv.slice(2)
 */
export async function main(argv) {
  const { command, subcommand, args, opts } = parseGlobalArgs(argv);

  if (opts.help || command === 'help' || command === '') {
    out.info(HELP);
    return;
  }

  try {
    switch (command) {
      case 'version':
        out.info(`agent-os v${getVersion()}`);
        break;

      case 'health': {
        const result = await http.get('/api/v1/health', opts);
        if (opts.json) {
          out.json(result);
        } else {
          out.success('Agent-OS is healthy.');
          out.json(result);
        }
        break;
      }

      case 'agent':
        switch (subcommand) {
          case 'create': await agentCmd.create(args, opts); break;
          case 'list':   await agentCmd.list(args, opts); break;
          case 'start':  await agentCmd.start(args, opts); break;
          case 'stop':   await agentCmd.stop(args, opts); break;
          case 'logs':   await agentCmd.logs(args, opts); break;
          default:
            out.error(`Unknown agent command: ${subcommand}`);
            out.info('Available: create, list, start, stop, logs');
            process.exit(1);
        }
        break;

      case 'job':
        switch (subcommand) {
          case 'submit': await jobCmd.submit(args, opts); break;
          case 'status': await jobCmd.status(args, opts); break;
          default:
            out.error(`Unknown job command: ${subcommand}`);
            out.info('Available: submit, status');
            process.exit(1);
        }
        break;

      case 'memory':
        switch (subcommand) {
          case 'search': await memoryCmd.search(args, opts); break;
          case 'show':   await memoryCmd.show(args, opts); break;
          default:
            out.error(`Unknown memory command: ${subcommand}`);
            out.info('Available: search, show');
            process.exit(1);
        }
        break;

      case 'deploy':
        switch (subcommand) {
          case 'docker': await deployCmd.docker(args, opts); break;
          case 'fly':    await deployCmd.fly(args, opts); break;
          default:
            out.error(`Unknown deploy command: ${subcommand}`);
            out.info('Available: docker, fly');
            process.exit(1);
        }
        break;

      default:
        out.error(`Unknown command: ${command}`);
        out.info('Run "agent-os --help" for usage.');
        process.exit(1);
    }
  } catch (e) {
    if (e.status) {
      out.error(e.message);
    } else if (e.cause?.code === 'ECONNREFUSED') {
      out.error(`Cannot connect to ${opts.host} — is Agent-OS running?`);
    } else {
      out.error(e.message || String(e));
    }
    process.exit(1);
  }
}

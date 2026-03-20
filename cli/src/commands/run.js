/**
 * Run commands — execute single agents or multi-stage pipelines.
 *
 *   agent-os run <type> --topic "..."
 *   agent-os run pipeline --contract <name> --topic "..."
 */

import * as http from '../http.js';
import * as out from '../output.js';

/**
 * Run a single agent.
 * @param {string[]} args - Positional args; args[0] is the agent type
 * @param {object} opts - Global + command-specific options
 */
export async function runSingle(args, opts) {
  const type = args[0];
  if (!type) {
    out.error('Usage: agent-os run <type> --topic "..."');
    process.exit(1);
  }
  if (!opts.topic) {
    out.error('--topic is required');
    process.exit(1);
  }

  out.info(`Running ${type} agent...`);
  out.info(`Topic: ${opts.topic}`);

  const body = {
    type,
    topic: opts.topic,
  };
  if (opts.model) body.model = opts.model;
  if (opts.provider) body.provider = opts.provider;

  const result = await http.post('/api/v1/run', body, opts);

  out.success('Pipeline completed!');

  if (opts.json) {
    out.json(result);
  } else if (result.artifacts) {
    out.info('Artifacts:');
    for (const a of result.artifacts) {
      out.info(`  - ${a.name || a.path || JSON.stringify(a)}`);
    }
  }

  return result;
}

/**
 * Run a multi-stage pipeline defined by a contract.
 * @param {string[]} args - Positional args (unused)
 * @param {object} opts - Global + command-specific options
 */
export async function runPipeline(args, opts) {
  if (!opts.contract) {
    out.error('--contract is required');
    process.exit(1);
  }
  if (!opts.topic) {
    out.error('--topic is required');
    process.exit(1);
  }

  out.info(`Running pipeline '${opts.contract}'...`);
  out.info(`Topic: ${opts.topic}`);

  const result = await http.post('/api/v1/pipeline/run', {
    contract: opts.contract,
    topic: opts.topic,
  }, opts);

  out.success('Pipeline completed!');

  if (opts.json) {
    out.json(result);
  } else {
    if (result.stages) {
      out.info('Stages:');
      for (const s of result.stages) {
        out.info(`  - ${s.name || s.stage}: ${s.status || 'done'}`);
      }
    }
    if (result.artifacts) {
      out.info('Artifacts:');
      for (const a of result.artifacts) {
        out.info(`  - ${a.name || a.path || JSON.stringify(a)}`);
      }
    }
  }

  return result;
}

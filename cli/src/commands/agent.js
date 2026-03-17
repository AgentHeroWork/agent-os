/**
 * Agent commands — create, list, start, stop, logs.
 */

import * as http from '../http.js';
import * as out from '../output.js';

/**
 * Create a new agent.
 * POST /api/v1/agents { type, name, oversight }
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function create(args, opts) {
  const type = opts.type;
  const name = opts.name;
  const oversight = opts.oversight ?? 'standard';

  if (!type) {
    out.error('--type is required (e.g. --type openclaw)');
    process.exit(1);
  }
  if (!name) {
    out.error('--name is required (e.g. --name "researcher-1")');
    process.exit(1);
  }

  const body = { type, name, oversight };
  if (opts.target) body.target = opts.target;

  const result = await http.post('/api/v1/agents', body, opts);

  if (opts.json) {
    out.json(result);
  } else {
    out.success(`Agent created: ${result.id || result.data?.id || 'ok'}`);
    out.json(result);
  }
}

/**
 * List all agents.
 * GET /api/v1/agents
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function list(args, opts) {
  const query = opts.target ? `?target=${opts.target}` : '';
  const result = await http.get(`/api/v1/agents${query}`, opts);

  if (opts.json) {
    out.json(result);
    return;
  }

  const agents = result.data || result.agents || result;
  if (!Array.isArray(agents) || agents.length === 0) {
    out.info('No agents found.');
    return;
  }

  const headers = ['ID', 'NAME', 'TYPE', 'STATUS', 'TARGET'];
  const rows = agents.map((a) => [
    a.id,
    a.name || '-',
    a.type || '-',
    a.status || '-',
    a.target || '-',
  ]);
  out.table(headers, rows);
}

/**
 * Start an agent with a job spec.
 * POST /api/v1/agents/:id/start { job_spec }
 * @param {string[]} args - Positional arguments (args[0] = agent id)
 * @param {object} opts - Global CLI options
 */
export async function start(args, opts) {
  const id = args[0];
  if (!id) {
    out.error('Agent ID is required: agent-os agent start <id>');
    process.exit(1);
  }

  let jobSpec = {};
  if (opts.job) {
    try {
      jobSpec = JSON.parse(opts.job);
    } catch (e) {
      out.error(`Invalid JSON in --job: ${e.message}`);
      process.exit(1);
    }
  }

  const result = await http.post(`/api/v1/agents/${id}/start`, { job_spec: jobSpec }, opts);

  if (opts.json) {
    out.json(result);
  } else {
    out.success(`Agent ${id} started.`);
  }
}

/**
 * Stop an agent.
 * POST /api/v1/agents/:id/stop
 * @param {string[]} args - Positional arguments (args[0] = agent id)
 * @param {object} opts - Global CLI options
 */
export async function stop(args, opts) {
  const id = args[0];
  if (!id) {
    out.error('Agent ID is required: agent-os agent stop <id>');
    process.exit(1);
  }

  const result = await http.post(`/api/v1/agents/${id}/stop`, {}, opts);

  if (opts.json) {
    out.json(result);
  } else {
    out.success(`Agent ${id} stopped.`);
  }
}

/**
 * Get agent logs.
 * GET /api/v1/agents/:id/logs
 * @param {string[]} args - Positional arguments (args[0] = agent id)
 * @param {object} opts - Global CLI options
 */
export async function logs(args, opts) {
  const id = args[0];
  if (!id) {
    out.error('Agent ID is required: agent-os agent logs <id>');
    process.exit(1);
  }

  // --follow is noted but basic implementation fetches once
  const result = await http.get(`/api/v1/agents/${id}/logs`, opts);

  if (opts.json) {
    out.json(result);
  } else {
    const lines = result.data || result.logs || result;
    if (Array.isArray(lines)) {
      for (const line of lines) {
        out.info(typeof line === 'string' ? line : JSON.stringify(line));
      }
    } else {
      out.json(result);
    }
  }
}

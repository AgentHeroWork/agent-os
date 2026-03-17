/**
 * Job commands — submit, status.
 */

import * as http from '../http.js';
import * as out from '../output.js';

/**
 * Submit a new job.
 * POST /api/v1/jobs { client_id, task, input }
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function submit(args, opts) {
  const task = opts.task;
  if (!task) {
    out.error('--task is required (e.g. --task research)');
    process.exit(1);
  }

  let input = {};
  if (opts.input) {
    try {
      input = JSON.parse(opts.input);
    } catch (e) {
      out.error(`Invalid JSON in --input: ${e.message}`);
      process.exit(1);
    }
  }

  const body = {
    client_id: 'cli',
    task,
    input,
  };

  const result = await http.post('/api/v1/jobs', body, opts);

  if (opts.json) {
    out.json(result);
  } else {
    out.success(`Job submitted: ${result.id || result.data?.id || 'ok'}`);
    out.json(result);
  }
}

/**
 * Get job status.
 * GET /api/v1/jobs/:id
 * @param {string[]} args - Positional arguments (args[0] = job id)
 * @param {object} opts - Global CLI options
 */
export async function status(args, opts) {
  const id = args[0];
  if (!id) {
    out.error('Job ID is required: agent-os job status <id>');
    process.exit(1);
  }

  const result = await http.get(`/api/v1/jobs/${id}`, opts);

  if (opts.json) {
    out.json(result);
  } else {
    const job = result.data || result;
    out.info(`Job:    ${job.id || id}`);
    out.info(`Status: ${job.status || 'unknown'}`);
    out.info(`Task:   ${job.task || '-'}`);
    if (job.result) {
      out.info(`Result:`);
      out.json(job.result);
    }
  }
}

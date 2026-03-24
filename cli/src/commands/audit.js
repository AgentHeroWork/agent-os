/**
 * Audit commands — trail.
 *
 *   agent-os audit <pipeline-id>
 */

import * as http from '../http.js';
import * as out from '../output.js';

/**
 * Show the audit trail for a pipeline run.
 * GET /api/v1/audit/:id
 * @param {string[]} args - Positional arguments (args[0] = pipeline id)
 * @param {object} opts - Global CLI options
 */
export async function trail(args, opts) {
  const id = args[0];
  if (!id) {
    out.error('Usage: agent-os audit <pipeline-id>');
    process.exit(1);
  }

  const result = await http.get(`/api/v1/audit/${id}`, opts);

  if (opts.json) {
    out.json(result);
    return;
  }

  const entries = result.data || result.entries || result;
  if (Array.isArray(entries) && entries.length > 0) {
    out.info(`Audit trail for ${id}:`);
    const headers = ['TIMESTAMP', 'STAGE', 'STATUS', 'DETAIL'];
    const rows = entries.map((e) => [
      e.timestamp || e.ts || '-',
      e.stage || e.name || '-',
      e.status || '-',
      (e.detail || e.message || '-').slice(0, 60),
    ]);
    out.table(headers, rows);
  } else if (Array.isArray(entries)) {
    out.info(`No audit entries found for ${id}.`);
  } else {
    out.json(entries);
  }
}

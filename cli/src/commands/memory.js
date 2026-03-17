/**
 * Memory commands — search, show.
 */

import * as http from '../http.js';
import * as out from '../output.js';

/**
 * Search memory.
 * GET /api/v1/memory/search?q=<query>
 * @param {string[]} args - Positional arguments (args[0] = search query)
 * @param {object} opts - Global CLI options
 */
export async function search(args, opts) {
  const query = args[0];
  if (!query) {
    out.error('Search query is required: agent-os memory search "query"');
    process.exit(1);
  }

  const encoded = encodeURIComponent(query);
  const result = await http.get(`/api/v1/memory/search?q=${encoded}`, opts);

  if (opts.json) {
    out.json(result);
    return;
  }

  const items = result.data || result.results || result;
  if (!Array.isArray(items) || items.length === 0) {
    out.info('No results found.');
    return;
  }

  const headers = ['ID', 'SCORE', 'SUMMARY'];
  const rows = items.map((item) => [
    item.id || '-',
    item.score != null ? String(item.score) : '-',
    (item.summary || item.content || '-').slice(0, 60),
  ]);
  out.table(headers, rows);
}

/**
 * Show a memory entry.
 * GET /api/v1/memory/:id
 * @param {string[]} args - Positional arguments (args[0] = memory id)
 * @param {object} opts - Global CLI options
 */
export async function show(args, opts) {
  const id = args[0];
  if (!id) {
    out.error('Memory ID is required: agent-os memory show <id>');
    process.exit(1);
  }

  const result = await http.get(`/api/v1/memory/${id}`, opts);

  if (opts.json) {
    out.json(result);
  } else {
    const entry = result.data || result;
    out.json(entry);
  }
}

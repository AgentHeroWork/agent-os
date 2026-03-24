/**
 * Contracts commands — list.
 *
 *   agent-os contracts list
 */

import * as http from '../http.js';
import * as out from '../output.js';

/**
 * List available contracts.
 * GET /api/v1/contracts
 * @param {string[]} args - Positional arguments
 * @param {object} opts - Global CLI options
 */
export async function listContracts(args, opts) {
  const result = await http.get('/api/v1/contracts', opts);

  if (opts.json) {
    out.json(result);
    return;
  }

  const contracts = result.contracts || result.data || result;
  if (Array.isArray(contracts) && contracts.length > 0) {
    out.info('Available contracts:');
    for (const name of contracts) {
      out.info(`  - ${typeof name === 'string' ? name : name.name || JSON.stringify(name)}`);
    }
  } else {
    out.info('No contracts found.');
  }
}

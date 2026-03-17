/**
 * Output formatting utilities for the Agent-OS CLI.
 * Provides table, JSON, info, error, and success output.
 */

/**
 * Print an ASCII table with auto-width columns.
 * @param {string[]} headers - Column headers
 * @param {Array<string[]>} rows - Table rows (each row is an array of cell values)
 */
export function table(headers, rows) {
  // Calculate column widths
  const widths = headers.map((h, i) => {
    const cellWidths = rows.map((row) => String(row[i] ?? '').length);
    return Math.max(h.length, ...cellWidths);
  });

  // Format a single row
  const formatRow = (cells) =>
    cells.map((cell, i) => String(cell ?? '').padEnd(widths[i])).join('  ');

  // Build separator
  const separator = widths.map((w) => '-'.repeat(w)).join('  ');

  console.log(formatRow(headers));
  console.log(separator);
  for (const row of rows) {
    console.log(formatRow(row));
  }
}

/**
 * Print pretty-formatted JSON.
 * @param {any} data - Data to serialize
 */
export function json(data) {
  console.log(JSON.stringify(data, null, 2));
}

/**
 * Print an info message to stdout.
 * @param {string} msg - Message
 */
export function info(msg) {
  console.log(msg);
}

/**
 * Print an error message to stderr.
 * @param {string} msg - Error message
 */
export function error(msg) {
  console.error(`Error: ${msg}`);
}

/**
 * Print a success message to stdout with a checkmark.
 * @param {string} msg - Success message
 */
export function success(msg) {
  console.log(`OK ${msg}`);
}

/**
 * HTTP client for the Agent-OS REST API.
 * Uses Node.js built-in fetch() (Node 18+).
 */

/**
 * Resolve the API host URL.
 * Priority: opts.host → AGENT_OS_HOST env → default.
 * @param {object} opts - Global CLI options
 * @returns {string} Base URL without trailing slash
 */
function resolveHost(opts = {}) {
  const host = opts.host || process.env.AGENT_OS_HOST || 'http://localhost:4000';
  return host.replace(/\/+$/, '');
}

/**
 * Resolve the API key.
 * Priority: opts.apiKey → AGENT_OS_API_KEY env → undefined.
 * @param {object} opts - Global CLI options
 * @returns {string|undefined}
 */
function resolveApiKey(opts = {}) {
  return opts.apiKey || process.env.AGENT_OS_API_KEY || undefined;
}

/**
 * Build common request headers.
 * @param {object} opts - Global CLI options
 * @returns {object} Headers object
 */
function buildHeaders(opts = {}) {
  const headers = { 'Content-Type': 'application/json' };
  const apiKey = resolveApiKey(opts);
  if (apiKey) {
    headers['Authorization'] = `Bearer ${apiKey}`;
  }
  return headers;
}

/**
 * Handle the response — parse JSON and throw on non-2xx.
 * @param {Response} res - Fetch Response
 * @returns {Promise<any>} Parsed JSON body
 */
async function handleResponse(res) {
  let body;
  const text = await res.text();
  try {
    body = JSON.parse(text);
  } catch {
    body = { message: text };
  }

  if (!res.ok) {
    const msg = body.message || body.error || JSON.stringify(body);
    const err = new Error(`HTTP ${res.status}: ${msg}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }

  return body;
}

/**
 * Perform a GET request.
 * @param {string} path - API path (e.g. "/api/v1/agents")
 * @param {object} opts - Global CLI options
 * @returns {Promise<any>} Response JSON
 */
export async function get(path, opts = {}) {
  const url = `${resolveHost(opts)}${path}`;
  const res = await fetch(url, {
    method: 'GET',
    headers: buildHeaders(opts),
  });
  return handleResponse(res);
}

/**
 * Perform a POST request.
 * @param {string} path - API path
 * @param {object} body - Request body (will be JSON-serialized)
 * @param {object} opts - Global CLI options
 * @returns {Promise<any>} Response JSON
 */
export async function post(path, body, opts = {}) {
  const url = `${resolveHost(opts)}${path}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: buildHeaders(opts),
    body: JSON.stringify(body),
  });
  return handleResponse(res);
}

/**
 * Perform a DELETE request.
 * @param {string} path - API path
 * @param {object} opts - Global CLI options
 * @returns {Promise<any>} Response JSON
 */
export async function del(path, opts = {}) {
  const url = `${resolveHost(opts)}${path}`;
  const res = await fetch(url, {
    method: 'DELETE',
    headers: buildHeaders(opts),
  });
  return handleResponse(res);
}

// Exported for testing
export { resolveHost, resolveApiKey };

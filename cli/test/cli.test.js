/**
 * Agent-OS CLI unit tests.
 * Uses the Node.js built-in test runner (node:test).
 *
 * Run: node --test test/cli.test.js
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { parseGlobalArgs } from '../src/main.js';
import { resolveHost, resolveApiKey } from '../src/http.js';
import * as out from '../src/output.js';

// ─── Global option parsing ───────────────────────────────────────────────────

describe('parseGlobalArgs', () => {
  it('should parse --target flag', () => {
    const { opts } = parseGlobalArgs(['agent', 'list', '--target', 'fly']);
    assert.equal(opts.target, 'fly');
  });

  it('should default target to local', () => {
    const { opts } = parseGlobalArgs(['agent', 'list']);
    assert.equal(opts.target, 'local');
  });

  it('should parse --host flag', () => {
    const { opts } = parseGlobalArgs(['health', '--host', 'http://example.com:9000']);
    assert.equal(opts.host, 'http://example.com:9000');
  });

  it('should default host to http://localhost:4000', () => {
    const { opts } = parseGlobalArgs(['health']);
    assert.equal(opts.host, 'http://localhost:4000');
  });

  it('should parse --json flag', () => {
    const { opts } = parseGlobalArgs(['agent', 'list', '--json']);
    assert.equal(opts.json, true);
  });

  it('should default --json to false', () => {
    const { opts } = parseGlobalArgs(['agent', 'list']);
    assert.equal(opts.json, false);
  });

  it('should parse --api-key flag', () => {
    const { opts } = parseGlobalArgs(['health', '--api-key', 'sk-test-123']);
    assert.equal(opts.apiKey, 'sk-test-123');
  });

  it('should parse --help flag', () => {
    const { opts } = parseGlobalArgs(['--help']);
    assert.equal(opts.help, true);
  });
});

// ─── Command routing ─────────────────────────────────────────────────────────

describe('command routing', () => {
  it('should extract command and subcommand', () => {
    const { command, subcommand } = parseGlobalArgs(['agent', 'create', '--type', 'openclaw']);
    assert.equal(command, 'agent');
    assert.equal(subcommand, 'create');
  });

  it('should extract positional args after subcommand', () => {
    const { command, subcommand, args } = parseGlobalArgs(['agent', 'start', 'abc-123']);
    assert.equal(command, 'agent');
    assert.equal(subcommand, 'start');
    assert.deepEqual(args, ['abc-123']);
  });

  it('should handle version command (no subcommand)', () => {
    const { command, subcommand } = parseGlobalArgs(['version']);
    assert.equal(command, 'version');
    assert.equal(subcommand, '');
  });

  it('should handle health command', () => {
    const { command } = parseGlobalArgs(['health']);
    assert.equal(command, 'health');
  });

  it('should route job commands', () => {
    const { command, subcommand, opts } = parseGlobalArgs([
      'job', 'submit', '--task', 'research', '--input', '{"topic":"CERN"}',
    ]);
    assert.equal(command, 'job');
    assert.equal(subcommand, 'submit');
    assert.equal(opts.task, 'research');
    assert.equal(opts.input, '{"topic":"CERN"}');
  });

  it('should route memory commands', () => {
    const { command, subcommand, args } = parseGlobalArgs(['memory', 'search', 'particle physics']);
    assert.equal(command, 'memory');
    assert.equal(subcommand, 'search');
    assert.deepEqual(args, ['particle physics']);
  });

  it('should route deploy commands', () => {
    const { command, subcommand, opts } = parseGlobalArgs([
      'deploy', 'fly', '--region', 'lax', '--app', 'my-os',
    ]);
    assert.equal(command, 'deploy');
    assert.equal(subcommand, 'fly');
    assert.equal(opts.region, 'lax');
    assert.equal(opts.app, 'my-os');
  });

  it('should handle empty argv as no command', () => {
    const { command } = parseGlobalArgs([]);
    assert.equal(command, '');
  });
});

// ─── HTTP client URL resolution ──────────────────────────────────────────────

describe('HTTP resolveHost', () => {
  it('should use opts.host when provided', () => {
    assert.equal(resolveHost({ host: 'http://myhost:5000' }), 'http://myhost:5000');
  });

  it('should strip trailing slashes', () => {
    assert.equal(resolveHost({ host: 'http://myhost:5000/' }), 'http://myhost:5000');
  });

  it('should default to localhost:4000 with empty opts', () => {
    // Save and clear env to test default
    const saved = process.env.AGENT_OS_HOST;
    delete process.env.AGENT_OS_HOST;
    try {
      assert.equal(resolveHost({}), 'http://localhost:4000');
    } finally {
      if (saved !== undefined) process.env.AGENT_OS_HOST = saved;
    }
  });

  it('should use AGENT_OS_HOST env when no opts.host', () => {
    const saved = process.env.AGENT_OS_HOST;
    process.env.AGENT_OS_HOST = 'http://env-host:8080';
    try {
      assert.equal(resolveHost({}), 'http://env-host:8080');
    } finally {
      if (saved !== undefined) {
        process.env.AGENT_OS_HOST = saved;
      } else {
        delete process.env.AGENT_OS_HOST;
      }
    }
  });
});

describe('HTTP resolveApiKey', () => {
  it('should use opts.apiKey when provided', () => {
    assert.equal(resolveApiKey({ apiKey: 'key-1' }), 'key-1');
  });

  it('should return undefined with no key', () => {
    const saved = process.env.AGENT_OS_API_KEY;
    delete process.env.AGENT_OS_API_KEY;
    try {
      assert.equal(resolveApiKey({}), undefined);
    } finally {
      if (saved !== undefined) process.env.AGENT_OS_API_KEY = saved;
    }
  });
});

// ─── Output formatting ──────────────────────────────────────────────────────

describe('output.table', () => {
  it('should format a table without throwing', () => {
    // Capture stdout
    const original = console.log;
    const lines = [];
    console.log = (msg) => lines.push(msg);
    try {
      out.table(['ID', 'NAME'], [['1', 'Alice'], ['2', 'Bob']]);
      assert.equal(lines.length, 4); // header + separator + 2 rows
      assert.ok(lines[0].includes('ID'));
      assert.ok(lines[0].includes('NAME'));
      assert.ok(lines[1].includes('--'));
      assert.ok(lines[2].includes('Alice'));
      assert.ok(lines[3].includes('Bob'));
    } finally {
      console.log = original;
    }
  });

  it('should handle empty rows', () => {
    const original = console.log;
    const lines = [];
    console.log = (msg) => lines.push(msg);
    try {
      out.table(['A', 'B'], []);
      assert.equal(lines.length, 2); // header + separator only
    } finally {
      console.log = original;
    }
  });
});

describe('output.json', () => {
  it('should output pretty-printed JSON', () => {
    const original = console.log;
    let output = '';
    console.log = (msg) => { output = msg; };
    try {
      out.json({ hello: 'world' });
      assert.equal(output, JSON.stringify({ hello: 'world' }, null, 2));
    } finally {
      console.log = original;
    }
  });
});

describe('output.error', () => {
  it('should write to stderr with Error prefix', () => {
    const original = console.error;
    let output = '';
    console.error = (msg) => { output = msg; };
    try {
      out.error('something broke');
      assert.ok(output.includes('Error:'));
      assert.ok(output.includes('something broke'));
    } finally {
      console.error = original;
    }
  });
});

describe('output.success', () => {
  it('should include OK prefix', () => {
    const original = console.log;
    let output = '';
    console.log = (msg) => { output = msg; };
    try {
      out.success('done');
      assert.ok(output.includes('OK'));
      assert.ok(output.includes('done'));
    } finally {
      console.log = original;
    }
  });
});

// ─── Command-specific option parsing ────────────────────────────────────────

describe('command-specific options', () => {
  it('should parse agent create options', () => {
    const { opts } = parseGlobalArgs(['agent', 'create', '--type', 'openclaw', '--name', 'r1']);
    assert.equal(opts.type, 'openclaw');
    assert.equal(opts.name, 'r1');
  });

  it('should parse agent start --job', () => {
    const { opts } = parseGlobalArgs([
      'agent', 'start', 'id1', '--job', '{"task":"research"}',
    ]);
    assert.equal(opts.job, '{"task":"research"}');
  });

  it('should parse --follow for agent logs', () => {
    const { opts } = parseGlobalArgs(['agent', 'logs', 'id1', '--follow']);
    assert.equal(opts.follow, true);
  });
});

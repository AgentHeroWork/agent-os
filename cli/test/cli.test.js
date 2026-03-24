/**
 * Agent-OS CLI unit tests.
 * Uses the Node.js built-in test runner (node:test).
 *
 * Run: node --test test/cli.test.js
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { parseGlobalArgs } from '../src/main.js';
import { resolveHost, resolveApiKey } from '../src/http.js';
import * as out from '../src/output.js';
import * as config from '../src/config.js';

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

// ─── Run command parsing ────────────────────────────────────────────────────

describe('run command parsing', () => {
  it('should parse "run openclaw --topic test"', () => {
    const { command, subcommand, opts } = parseGlobalArgs([
      'run', 'openclaw', '--topic', 'quantum computing',
    ]);
    assert.equal(command, 'run');
    assert.equal(subcommand, 'openclaw');
    assert.equal(opts.topic, 'quantum computing');
  });

  it('should parse "run pipeline --contract research-report --topic test"', () => {
    const { command, subcommand, opts } = parseGlobalArgs([
      'run', 'pipeline', '--contract', 'research-report', '--topic', 'dark matter',
    ]);
    assert.equal(command, 'run');
    assert.equal(subcommand, 'pipeline');
    assert.equal(opts.contract, 'research-report');
    assert.equal(opts.topic, 'dark matter');
  });

  it('should parse optional --model and --provider flags', () => {
    const { opts } = parseGlobalArgs([
      'run', 'openclaw', '--topic', 'test', '--model', 'gpt-4', '--provider', 'openai',
    ]);
    assert.equal(opts.model, 'gpt-4');
    assert.equal(opts.provider, 'openai');
  });

  it('should have undefined topic when --topic is omitted', () => {
    const { opts } = parseGlobalArgs(['run', 'openclaw']);
    assert.equal(opts.topic, undefined);
  });
});

// ─── Config load/save ───────────────────────────────────────────────────────

describe('config', () => {
  const testDir = join(tmpdir(), `agent-os-test-${Date.now()}`);
  const testFile = join(testDir, 'config.json');

  it('should load empty config when file does not exist', () => {
    const result = config.load();
    // load() returns {} or existing config — just verify it returns an object
    assert.equal(typeof result, 'object');
  });

  it('should set and get a value', () => {
    config.set('testKey', 'testValue');
    const val = config.get('testKey');
    assert.equal(val, 'testValue');
    // Clean up
    config.set('testKey', undefined);
  });

  it('should overwrite an existing value', () => {
    config.set('overwriteTest', 'first');
    assert.equal(config.get('overwriteTest'), 'first');
    config.set('overwriteTest', 'second');
    assert.equal(config.get('overwriteTest'), 'second');
    // Clean up
    config.set('overwriteTest', undefined);
  });

  it('should return undefined for non-existent keys', () => {
    const val = config.get('definitely_does_not_exist_key');
    assert.equal(val, undefined);
  });
});

// ─── Login/logout command parsing ────────────────────────────────────────────

describe('login/logout command parsing', () => {
  it('should route login command', () => {
    const { command } = parseGlobalArgs(['login', '--api-key', 'sk-test']);
    assert.equal(command, 'login');
  });

  it('should parse --api-key for login', () => {
    const { command, opts } = parseGlobalArgs(['login', '--api-key', 'sk-abc']);
    assert.equal(command, 'login');
    assert.equal(opts.apiKey, 'sk-abc');
  });

  it('should parse --host for login', () => {
    const { opts } = parseGlobalArgs(['login', '--host', 'https://prod.example.com']);
    assert.equal(opts.host, 'https://prod.example.com');
  });

  it('should route logout command', () => {
    const { command } = parseGlobalArgs(['logout']);
    assert.equal(command, 'logout');
  });
});

// ─── Audit command parsing ──────────────────────────────────────────────────

describe('audit command parsing', () => {
  it('should route audit command with pipeline id', () => {
    const { command, subcommand } = parseGlobalArgs(['audit', 'pipe-123']);
    assert.equal(command, 'audit');
    assert.equal(subcommand, 'pipe-123');
  });

  it('should route audit command with --json flag', () => {
    const { command, subcommand, opts } = parseGlobalArgs(['audit', 'pipe-456', '--json']);
    assert.equal(command, 'audit');
    assert.equal(subcommand, 'pipe-456');
    assert.equal(opts.json, true);
  });

  it('should handle audit with no id', () => {
    const { command, subcommand } = parseGlobalArgs(['audit']);
    assert.equal(command, 'audit');
    assert.equal(subcommand, '');
  });
});

// ─── Contracts command parsing ──────────────────────────────────────────────

describe('contracts command parsing', () => {
  it('should route contracts list command', () => {
    const { command, subcommand } = parseGlobalArgs(['contracts', 'list']);
    assert.equal(command, 'contracts');
    assert.equal(subcommand, 'list');
  });

  it('should route contracts list with --json', () => {
    const { command, subcommand, opts } = parseGlobalArgs(['contracts', 'list', '--json']);
    assert.equal(command, 'contracts');
    assert.equal(subcommand, 'list');
    assert.equal(opts.json, true);
  });
});

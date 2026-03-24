'use client';

import { useState, useEffect, useCallback } from 'react';

interface ToolInfo {
  name: string;
  description?: string;
}

export default function SettingsPage() {
  const [host, setHost] = useState('http://localhost:4000');
  const [tools, setTools] = useState<ToolInfo[]>([]);
  const [toolsLoading, setToolsLoading] = useState(true);
  const [toolsError, setToolsError] = useState<string | null>(null);

  const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

  useEffect(() => {
    setHost(baseUrl);
  }, [baseUrl]);

  const fetchTools = useCallback(async () => {
    try {
      const res = await fetch(`${baseUrl}/api/v1/tools`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setTools(Array.isArray(data) ? data : data.tools || []);
      setToolsError(null);
    } catch (err) {
      setToolsError(err instanceof Error ? err.message : 'Failed to fetch tools');
    } finally {
      setToolsLoading(false);
    }
  }, [baseUrl]);

  useEffect(() => {
    fetchTools();
  }, [fetchTools]);

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold text-gray-100">Settings</h1>

      {/* Server configuration */}
      <div className="rounded-xl bg-gray-900 border border-gray-800 p-6">
        <h2 className="text-lg font-semibold text-gray-100 mb-4">Server Configuration</h2>
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-400 mb-1">
              Agent-OS Host
            </label>
            <input
              type="text"
              value={host}
              disabled
              className="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-gray-400 cursor-not-allowed"
            />
            <p className="text-xs text-gray-500 mt-1">
              Set via NEXT_PUBLIC_AGENT_OS_HOST environment variable
            </p>
          </div>
        </div>
      </div>

      {/* Registered tools */}
      <div className="rounded-xl bg-gray-900 border border-gray-800 p-6">
        <h2 className="text-lg font-semibold text-gray-100 mb-4">Registered Tools</h2>
        {toolsLoading ? (
          <p className="text-sm text-gray-500">Loading tools...</p>
        ) : toolsError ? (
          <div>
            <p className="text-sm text-red-400">Failed to load tools</p>
            <p className="text-xs text-gray-500 mt-1">{toolsError}</p>
          </div>
        ) : tools.length === 0 ? (
          <p className="text-sm text-gray-500">No tools registered.</p>
        ) : (
          <div className="space-y-2">
            {tools.map((tool) => (
              <div
                key={tool.name}
                className="flex items-center justify-between rounded-lg bg-gray-800 border border-gray-700 px-4 py-3"
              >
                <div>
                  <p className="text-sm font-medium text-gray-200">{tool.name}</p>
                  {tool.description && (
                    <p className="text-xs text-gray-500 mt-0.5">{tool.description}</p>
                  )}
                </div>
                <span className="inline-flex items-center rounded-full bg-green-500/10 text-green-400 border border-green-500/20 px-2.5 py-0.5 text-xs font-medium">
                  active
                </span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* About */}
      <div className="rounded-xl bg-gray-900 border border-gray-800 p-6">
        <h2 className="text-lg font-semibold text-gray-100 mb-4">About</h2>
        <div className="space-y-2 text-sm text-gray-400">
          <p>Agent-OS is an AI Operating System built on Erlang/OTP.</p>
          <p>Agents run in microsandbox microVMs with hardware-level isolation.</p>
          <p>Contracts (YAML) define what agents produce. The LLM decides which tools to use.</p>
        </div>
      </div>
    </div>
  );
}

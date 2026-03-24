'use client';

import { useEffect, useState, useCallback } from 'react';

interface Agent {
  id: string;
  type: string;
  status: string;
  oversight: string;
  created_at: string;
  name?: string;
}

export default function AgentsPage() {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

  const fetchAgents = useCallback(async () => {
    try {
      const res = await fetch(`${baseUrl}/api/v1/agents`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setAgents(Array.isArray(data) ? data : data.agents || []);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch agents');
    } finally {
      setLoading(false);
    }
  }, [baseUrl]);

  useEffect(() => {
    fetchAgents();
    const interval = setInterval(fetchAgents, 10000);
    return () => clearInterval(interval);
  }, [fetchAgents]);

  const statusColor = (status: string) => {
    const colors: Record<string, string> = {
      running: 'bg-green-500',
      active: 'bg-green-500',
      pending: 'bg-yellow-500',
      idle: 'bg-gray-500',
      failed: 'bg-red-500',
      stopped: 'bg-red-500',
      completed: 'bg-blue-500',
    };
    return colors[status] || 'bg-gray-500';
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-gray-100">Agents</h1>
        <button
          onClick={fetchAgents}
          className="inline-flex items-center gap-2 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm font-medium text-gray-300 hover:bg-gray-700 transition-colors"
        >
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182" />
          </svg>
          Refresh
        </button>
      </div>

      <div className="rounded-xl bg-gray-900 border border-gray-800 overflow-hidden">
        {loading ? (
          <div className="px-5 py-12 text-center text-gray-500">Loading agents...</div>
        ) : error ? (
          <div className="px-5 py-12 text-center text-red-400">
            <p className="font-medium">Failed to load agents</p>
            <p className="text-sm text-gray-500 mt-1">{error}</p>
          </div>
        ) : agents.length === 0 ? (
          <div className="px-5 py-12 text-center text-gray-500">
            <p className="font-medium">No agents found</p>
            <p className="text-sm mt-1">Create an agent to get started.</p>
          </div>
        ) : (
          <table className="w-full text-sm text-left">
            <thead>
              <tr className="border-b border-gray-800 text-gray-400">
                <th className="px-5 py-3 font-medium">ID</th>
                <th className="px-5 py-3 font-medium">Type</th>
                <th className="px-5 py-3 font-medium">Status</th>
                <th className="px-5 py-3 font-medium">Oversight</th>
                <th className="px-5 py-3 font-medium">Created</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-800">
              {agents.map((agent) => (
                <tr key={agent.id} className="hover:bg-gray-800/50 transition-colors">
                  <td className="px-5 py-3">
                    <span className="font-mono text-xs text-gray-300">{agent.id}</span>
                  </td>
                  <td className="px-5 py-3 text-gray-300">{agent.type}</td>
                  <td className="px-5 py-3">
                    <span className="inline-flex items-center gap-1.5">
                      <span className={`w-2 h-2 rounded-full ${statusColor(agent.status)}`} />
                      <span className="text-gray-300">{agent.status}</span>
                    </span>
                  </td>
                  <td className="px-5 py-3 text-gray-300">{agent.oversight || '--'}</td>
                  <td className="px-5 py-3 text-gray-500">{agent.created_at || '--'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

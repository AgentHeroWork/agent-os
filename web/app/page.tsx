'use client';

import { useEffect, useState, useCallback } from 'react';
import Link from 'next/link';

interface HealthData {
  status: string;
}

interface Agent {
  id: string;
  type: string;
  status: string;
}

export default function DashboardPage() {
  const [health, setHealth] = useState<HealthData | null>(null);
  const [healthError, setHealthError] = useState(false);
  const [agents, setAgents] = useState<Agent[]>([]);
  const [agentsError, setAgentsError] = useState(false);

  const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

  const fetchData = useCallback(async () => {
    try {
      const res = await fetch(`${baseUrl}/api/v1/health`, { cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        setHealth(data);
        setHealthError(false);
      } else {
        setHealthError(true);
      }
    } catch {
      setHealthError(true);
    }

    try {
      const res = await fetch(`${baseUrl}/api/v1/agents`, { cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        setAgents(Array.isArray(data) ? data : data.agents || []);
        setAgentsError(false);
      } else {
        setAgentsError(true);
      }
    } catch {
      setAgentsError(true);
    }
  }, [baseUrl]);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 15000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const activeAgents = agents.filter((a) => a.status === 'running' || a.status === 'active');

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-gray-100">Dashboard</h1>
        <Link
          href="/pipelines"
          className="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500 transition-colors"
        >
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M5.25 5.653c0-.856.917-1.398 1.667-.986l11.54 6.347a1.125 1.125 0 0 1 0 1.972l-11.54 6.347a1.125 1.125 0 0 1-1.667-.986V5.653Z" />
          </svg>
          Run Pipeline
        </Link>
      </div>

      {/* Status cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        {/* Health */}
        <div className="rounded-xl bg-gray-900 border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-3">
            <span className="text-sm font-medium text-gray-400">Server Health</span>
            <span
              className={`inline-block w-3 h-3 rounded-full ${
                healthError ? 'bg-red-500' : 'bg-green-500'
              }`}
            />
          </div>
          <p className="text-2xl font-bold">
            {healthError ? 'Offline' : health?.status || 'Checking...'}
          </p>
        </div>

        {/* Agent count */}
        <div className="rounded-xl bg-gray-900 border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-3">
            <span className="text-sm font-medium text-gray-400">Total Agents</span>
            <svg className="w-5 h-5 text-gray-500" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M15 19.128a9.38 9.38 0 0 0 2.625.372 9.337 9.337 0 0 0 4.121-.952 4.125 4.125 0 0 0-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 0 1 8.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0 1 11.964-3.07M12 6.375a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0Zm8.25 2.25a2.625 2.625 0 1 1-5.25 0 2.625 2.625 0 0 1 5.25 0Z" />
            </svg>
          </div>
          <p className="text-2xl font-bold">
            {agentsError ? '--' : agents.length}
          </p>
        </div>

        {/* Active pipelines */}
        <div className="rounded-xl bg-gray-900 border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-3">
            <span className="text-sm font-medium text-gray-400">Active Agents</span>
            <svg className="w-5 h-5 text-gray-500" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25H12" />
            </svg>
          </div>
          <p className="text-2xl font-bold">
            {agentsError ? '--' : activeAgents.length}
          </p>
        </div>
      </div>

      {/* Recent agents */}
      <div className="rounded-xl bg-gray-900 border border-gray-800">
        <div className="px-5 py-4 border-b border-gray-800">
          <h2 className="text-lg font-semibold text-gray-100">Recent Agents</h2>
        </div>
        <div className="divide-y divide-gray-800">
          {agentsError ? (
            <div className="px-5 py-8 text-center text-gray-500">
              Could not connect to Agent-OS server
            </div>
          ) : agents.length === 0 ? (
            <div className="px-5 py-8 text-center text-gray-500">
              No agents found. Create one to get started.
            </div>
          ) : (
            agents.slice(0, 10).map((agent) => (
              <div key={agent.id} className="flex items-center justify-between px-5 py-3">
                <div>
                  <p className="text-sm font-medium text-gray-200">{agent.id}</p>
                  <p className="text-xs text-gray-500">{agent.type}</p>
                </div>
                <StatusBadge status={agent.status} />
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const colors: Record<string, string> = {
    running: 'bg-green-500/10 text-green-400 border-green-500/20',
    active: 'bg-green-500/10 text-green-400 border-green-500/20',
    pending: 'bg-yellow-500/10 text-yellow-400 border-yellow-500/20',
    idle: 'bg-gray-500/10 text-gray-400 border-gray-500/20',
    failed: 'bg-red-500/10 text-red-400 border-red-500/20',
    stopped: 'bg-red-500/10 text-red-400 border-red-500/20',
    completed: 'bg-blue-500/10 text-blue-400 border-blue-500/20',
  };

  const colorClass = colors[status] || colors.idle;

  return (
    <span className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium ${colorClass}`}>
      {status}
    </span>
  );
}

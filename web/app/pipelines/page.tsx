'use client';

import { useEffect, useState, useCallback } from 'react';

interface Contract {
  name: string;
  description?: string;
}

interface PipelineResult {
  pipeline_id?: string;
  status?: string;
  message?: string;
  error?: string;
}

export default function PipelinesPage() {
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [selectedContract, setSelectedContract] = useState('');
  const [topic, setTopic] = useState('');
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState<PipelineResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [contractsError, setContractsError] = useState(false);

  const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

  const fetchContracts = useCallback(async () => {
    try {
      const res = await fetch(`${baseUrl}/api/v1/contracts`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const list = Array.isArray(data) ? data : data.contracts || [];
      setContracts(list);
      if (list.length > 0 && !selectedContract) {
        setSelectedContract(list[0].name);
      }
      setContractsError(false);
    } catch {
      setContractsError(true);
    }
  }, [baseUrl, selectedContract]);

  useEffect(() => {
    fetchContracts();
  }, [fetchContracts]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!selectedContract || !topic.trim()) return;

    setRunning(true);
    setResult(null);
    setError(null);

    try {
      const res = await fetch(`${baseUrl}/api/v1/pipeline/run`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ contract: selectedContract, topic: topic.trim() }),
        cache: 'no-store',
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || `HTTP ${res.status}`);
      } else {
        setResult(data);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to run pipeline');
    } finally {
      setRunning(false);
    }
  }

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold text-gray-100">Pipelines</h1>

      {/* Run pipeline form */}
      <div className="rounded-xl bg-gray-900 border border-gray-800 p-6">
        <h2 className="text-lg font-semibold text-gray-100 mb-4">Run a Pipeline</h2>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label htmlFor="contract" className="block text-sm font-medium text-gray-400 mb-1">
              Contract
            </label>
            {contractsError ? (
              <p className="text-sm text-red-400">Could not load contracts from server</p>
            ) : (
              <select
                id="contract"
                value={selectedContract}
                onChange={(e) => setSelectedContract(e.target.value)}
                className="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-gray-200 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
              >
                {contracts.length === 0 && (
                  <option value="">No contracts available</option>
                )}
                {contracts.map((c) => (
                  <option key={c.name} value={c.name}>
                    {c.name}
                  </option>
                ))}
              </select>
            )}
          </div>

          <div>
            <label htmlFor="topic" className="block text-sm font-medium text-gray-400 mb-1">
              Topic
            </label>
            <input
              id="topic"
              type="text"
              value={topic}
              onChange={(e) => setTopic(e.target.value)}
              placeholder="Enter the topic for this pipeline run..."
              className="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
            />
          </div>

          <button
            type="submit"
            disabled={running || !selectedContract || !topic.trim()}
            className="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {running ? (
              <>
                <svg className="w-4 h-4 animate-spin" viewBox="0 0 24 24" fill="none">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                </svg>
                Running...
              </>
            ) : (
              <>
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5.25 5.653c0-.856.917-1.398 1.667-.986l11.54 6.347a1.125 1.125 0 0 1 0 1.972l-11.54 6.347a1.125 1.125 0 0 1-1.667-.986V5.653Z" />
                </svg>
                Run Pipeline
              </>
            )}
          </button>
        </form>

        {/* Result */}
        {error && (
          <div className="mt-4 rounded-lg bg-red-500/10 border border-red-500/20 px-4 py-3">
            <p className="text-sm font-medium text-red-400">Error</p>
            <p className="text-sm text-red-300 mt-1">{error}</p>
          </div>
        )}

        {result && (
          <div className="mt-4 rounded-lg bg-green-500/10 border border-green-500/20 px-4 py-3">
            <p className="text-sm font-medium text-green-400">Pipeline Started</p>
            {result.pipeline_id && (
              <p className="text-sm text-green-300 mt-1">Pipeline ID: {result.pipeline_id}</p>
            )}
            {result.status && (
              <p className="text-sm text-green-300 mt-1">Status: {result.status}</p>
            )}
            {result.message && (
              <p className="text-sm text-green-300 mt-1">{result.message}</p>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

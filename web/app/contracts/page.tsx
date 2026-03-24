'use client';

import { useEffect, useState, useCallback } from 'react';

interface Contract {
  name: string;
  description?: string;
  stages?: Array<{ name: string; output?: string[] }>;
  required_artifacts?: string[];
}

export default function ContractsPage() {
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);

  const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

  const fetchContracts = useCallback(async () => {
    try {
      const res = await fetch(`${baseUrl}/api/v1/contracts`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setContracts(Array.isArray(data) ? data : data.contracts || []);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch contracts');
    } finally {
      setLoading(false);
    }
  }, [baseUrl]);

  useEffect(() => {
    fetchContracts();
  }, [fetchContracts]);

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold text-gray-100">Contracts</h1>

      {loading ? (
        <div className="rounded-xl bg-gray-900 border border-gray-800 px-5 py-12 text-center text-gray-500">
          Loading contracts...
        </div>
      ) : error ? (
        <div className="rounded-xl bg-gray-900 border border-gray-800 px-5 py-12 text-center">
          <p className="font-medium text-red-400">Failed to load contracts</p>
          <p className="text-sm text-gray-500 mt-1">{error}</p>
        </div>
      ) : contracts.length === 0 ? (
        <div className="rounded-xl bg-gray-900 border border-gray-800 px-5 py-12 text-center text-gray-500">
          No contracts found.
        </div>
      ) : (
        <div className="space-y-3">
          {contracts.map((contract) => (
            <div
              key={contract.name}
              className="rounded-xl bg-gray-900 border border-gray-800 overflow-hidden"
            >
              <button
                onClick={() =>
                  setExpanded(expanded === contract.name ? null : contract.name)
                }
                className="w-full flex items-center justify-between px-5 py-4 text-left hover:bg-gray-800/50 transition-colors"
              >
                <div>
                  <p className="text-sm font-semibold text-gray-200">{contract.name}</p>
                  {contract.description && (
                    <p className="text-xs text-gray-500 mt-0.5">{contract.description}</p>
                  )}
                </div>
                <svg
                  className={`w-5 h-5 text-gray-500 transition-transform ${
                    expanded === contract.name ? 'rotate-180' : ''
                  }`}
                  fill="none"
                  viewBox="0 0 24 24"
                  strokeWidth={1.5}
                  stroke="currentColor"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    d="m19.5 8.25-7.5 7.5-7.5-7.5"
                  />
                </svg>
              </button>

              {expanded === contract.name && (
                <div className="px-5 pb-4 border-t border-gray-800 pt-4 space-y-3">
                  {contract.stages && contract.stages.length > 0 && (
                    <div>
                      <h3 className="text-xs font-medium text-gray-400 uppercase tracking-wide mb-2">
                        Stages
                      </h3>
                      <div className="space-y-2">
                        {contract.stages.map((stage, i) => (
                          <div
                            key={stage.name}
                            className="flex items-center gap-3 text-sm"
                          >
                            <span className="flex-shrink-0 w-6 h-6 rounded-full bg-gray-800 border border-gray-700 flex items-center justify-center text-xs text-gray-400">
                              {i + 1}
                            </span>
                            <span className="text-gray-300">{stage.name}</span>
                            {stage.output && (
                              <span className="text-xs text-gray-500">
                                {stage.output.join(', ')}
                              </span>
                            )}
                          </div>
                        ))}
                      </div>
                    </div>
                  )}

                  {contract.required_artifacts &&
                    contract.required_artifacts.length > 0 && (
                      <div>
                        <h3 className="text-xs font-medium text-gray-400 uppercase tracking-wide mb-2">
                          Required Artifacts
                        </h3>
                        <div className="flex flex-wrap gap-2">
                          {contract.required_artifacts.map((artifact) => (
                            <span
                              key={artifact}
                              className="inline-flex items-center rounded-md bg-gray-800 border border-gray-700 px-2 py-1 text-xs font-mono text-gray-300"
                            >
                              {artifact}
                            </span>
                          ))}
                        </div>
                      </div>
                    )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

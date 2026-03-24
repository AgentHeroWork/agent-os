'use client';

import { useState } from 'react';

interface AuditEvent {
  timestamp?: string;
  stage?: string;
  event?: string;
  type?: string;
  message?: string;
  status?: string;
  details?: Record<string, unknown>;
}

export default function AuditPage() {
  const [pipelineId, setPipelineId] = useState('');
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [searched, setSearched] = useState(false);

  const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

  async function handleSearch(e: React.FormEvent) {
    e.preventDefault();
    if (!pipelineId.trim()) return;

    setLoading(true);
    setError(null);
    setSearched(true);

    try {
      const res = await fetch(`${baseUrl}/api/v1/audit/${pipelineId.trim()}`, {
        cache: 'no-store',
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const eventList = Array.isArray(data) ? data : data.events || data.audit || [];
      setEvents(eventList);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch audit');
      setEvents([]);
    } finally {
      setLoading(false);
    }
  }

  const eventColor = (event: AuditEvent) => {
    const status = event.status || event.type || event.event || '';
    if (status.includes('fail') || status.includes('error')) return 'border-red-500 bg-red-500';
    if (status.includes('success') || status.includes('complete')) return 'border-green-500 bg-green-500';
    if (status.includes('start') || status.includes('running')) return 'border-blue-500 bg-blue-500';
    return 'border-gray-500 bg-gray-500';
  };

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold text-gray-100">Audit Trail</h1>

      {/* Search form */}
      <div className="rounded-xl bg-gray-900 border border-gray-800 p-6">
        <form onSubmit={handleSearch} className="flex items-end gap-3">
          <div className="flex-1">
            <label htmlFor="pipeline-id" className="block text-sm font-medium text-gray-400 mb-1">
              Pipeline ID
            </label>
            <input
              id="pipeline-id"
              type="text"
              value={pipelineId}
              onChange={(e) => setPipelineId(e.target.value)}
              placeholder="Enter pipeline ID to view audit trail..."
              className="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
            />
          </div>
          <button
            type="submit"
            disabled={loading || !pipelineId.trim()}
            className="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {loading ? 'Loading...' : 'Search'}
          </button>
        </form>
      </div>

      {/* Results */}
      {error && (
        <div className="rounded-xl bg-red-500/10 border border-red-500/20 px-5 py-4">
          <p className="text-sm font-medium text-red-400">Error</p>
          <p className="text-sm text-red-300 mt-1">{error}</p>
        </div>
      )}

      {searched && !loading && !error && events.length === 0 && (
        <div className="rounded-xl bg-gray-900 border border-gray-800 px-5 py-12 text-center text-gray-500">
          No audit events found for this pipeline.
        </div>
      )}

      {events.length > 0 && (
        <div className="rounded-xl bg-gray-900 border border-gray-800 p-6">
          <h2 className="text-lg font-semibold text-gray-100 mb-4">Timeline</h2>
          <div className="relative space-y-0">
            {/* Vertical line */}
            <div className="absolute left-3 top-2 bottom-2 w-px bg-gray-800" />

            {events.map((event, i) => (
              <div key={i} className="relative flex items-start gap-4 py-3">
                {/* Dot */}
                <div
                  className={`relative z-10 flex-shrink-0 w-6 h-6 rounded-full border-2 ${eventColor(event)}/20`}
                >
                  <div className={`absolute inset-1 rounded-full ${eventColor(event)}`} />
                </div>

                {/* Content */}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    {event.stage && (
                      <span className="inline-flex items-center rounded-md bg-gray-800 border border-gray-700 px-2 py-0.5 text-xs font-medium text-gray-300">
                        {event.stage}
                      </span>
                    )}
                    <span className="text-sm font-medium text-gray-200">
                      {event.event || event.type || event.message || 'Event'}
                    </span>
                  </div>
                  {event.timestamp && (
                    <p className="text-xs text-gray-500 mt-1">{event.timestamp}</p>
                  )}
                  {event.details && Object.keys(event.details).length > 0 && (
                    <pre className="mt-2 text-xs text-gray-500 bg-gray-800/50 rounded-lg p-2 overflow-x-auto">
                      {JSON.stringify(event.details, null, 2)}
                    </pre>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

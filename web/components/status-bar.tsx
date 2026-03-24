'use client';

import { useEffect, useState } from 'react';

export default function StatusBar() {
  const [status, setStatus] = useState<'healthy' | 'degraded' | 'offline'>('offline');
  const [lastCheck, setLastCheck] = useState<string>('');

  useEffect(() => {
    const baseUrl = process.env.NEXT_PUBLIC_AGENT_OS_HOST || 'http://localhost:4000';

    async function checkHealth() {
      try {
        const res = await fetch(`${baseUrl}/api/v1/health`, { cache: 'no-store' });
        if (res.ok) {
          setStatus('healthy');
        } else {
          setStatus('degraded');
        }
      } catch {
        setStatus('offline');
      }
      setLastCheck(new Date().toLocaleTimeString());
    }

    checkHealth();
    const interval = setInterval(checkHealth, 10000);
    return () => clearInterval(interval);
  }, []);

  const statusColor = {
    healthy: 'bg-green-500',
    degraded: 'bg-yellow-500',
    offline: 'bg-red-500',
  }[status];

  const statusLabel = {
    healthy: 'Server Healthy',
    degraded: 'Server Degraded',
    offline: 'Server Offline',
  }[status];

  return (
    <div className="flex items-center justify-between px-5 py-2 bg-gray-900 border-t border-gray-800 text-xs text-gray-400">
      <div className="flex items-center gap-2">
        <span className={`inline-block w-2 h-2 rounded-full ${statusColor}`} />
        <span>{statusLabel}</span>
      </div>
      {lastCheck && <span>Last check: {lastCheck}</span>}
    </div>
  );
}

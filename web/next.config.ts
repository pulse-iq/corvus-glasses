import { withWorkflow } from 'workflow/next';
import type { NextConfig } from 'next';

const config: NextConfig = {
  // The service and its deployment artifact are contained entirely in web/.
  outputFileTracingRoot: process.cwd(),
  async headers() {
    return [{ source: '/api/glasses/:path*', headers: [
      { key: 'Cache-Control', value: 'no-store' },
      { key: 'X-Content-Type-Options', value: 'nosniff' }
    ] }];
  }
};

export default withWorkflow(config);

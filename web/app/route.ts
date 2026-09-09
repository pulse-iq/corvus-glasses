export function GET() {
  return Response.json({ service: 'corvus-glasses', apiBasePath: '/api/glasses' });
}

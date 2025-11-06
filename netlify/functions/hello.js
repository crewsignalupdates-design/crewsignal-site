exports.handler = async () => ({
  statusCode: 200,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ ok: true, message: 'Hello from Netlify Functions' })
});

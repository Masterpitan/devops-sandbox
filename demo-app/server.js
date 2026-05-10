const express = require('express');
const app = express();
const ENV_ID = process.env.ENV_ID || 'unknown';
const PORT = 3000;

app.get('/', (req, res) => {
  res.json({ message: 'Hello from sandbox!', env: ENV_ID, time: new Date().toISOString() });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', env: ENV_ID, uptime: process.uptime() });
});

app.listen(PORT, () => console.log(`[app] env=${ENV_ID} listening on :${PORT}`));

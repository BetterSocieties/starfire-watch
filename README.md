# starfire-watch

Public, free runner for Starfire (public repos get unlimited free GitHub Actions minutes).
No business data lives in this repo. Private workflow definitions and the pod address are
pulled into the ephemeral CI runner at run time via encrypted secrets and never stored here.

- monitor.yml: every 2h a real browser checks the public Starfire web surfaces, commits data/live-health.json.
- n8n-restore.yml: no-op until secrets N8N_API_KEY + CORE_READ_TOKEN exist, then restores all
  n8n workflows from the private starfire-core repo onto the n8n pod.

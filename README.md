# FX Weekly Bias dashboard

Installable offline web app (PWA) for the weekly Sarmaaya-based currency bias model.
Open https://aamirrehansh.github.io/fx-bias-dashboard/ and install it to the home screen.

- `data/weeks.js` – every weekly model since 19–23 Oct 2026 (built by `tools/extract_weeks.py` from the Excel files).
- `data/rates.js` – bundled ECB daily rates (performance works offline); refreshed from frankfurter.dev when online.
- `data/plan.csv` – current week's plan, read by the MT5 **FX Bias Monitor** EA (`mt5/`).
- Live values: the EA writes `data/live.json` to the `live` branch; the app reads it via the GitHub API.

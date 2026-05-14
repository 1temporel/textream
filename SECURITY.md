# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | ✅ |
| Older releases | ❌ |

Only the latest release receives security updates. Please keep Textream up to date.

## Reporting a Vulnerability

If you discover a security vulnerability in Textream, **please do not open a public issue.**

Instead, report it privately:

- **Email:** [fka@fka.dev](mailto:fka@fka.dev)
- **Subject:** `[SECURITY] Textream — <brief description>`

Please include:

1. A description of the vulnerability
2. Steps to reproduce the issue
3. Potential impact
4. Suggested fix (if any)

You should receive an acknowledgment within **48 hours**. Once confirmed, a fix will be prioritized and released as soon as possible.

## Security Considerations

### On-Device Processing

All speech recognition runs locally via Apple's Speech framework. No audio data, transcripts, or scripts are sent to external servers. There are no accounts, analytics, or telemetry.

### Network Servers

Textream includes two optional network servers that bind to your **local network only**:

| Server | Default Port | Purpose |
|--------|-------------|---------|
| **Remote Connection** (BrowserServer) | `7373` / `7374` | Read-only teleprompter mirror for a browser |
| **Director Mode** (DirectorServer) | `7575` / `7576` | Remote script editing via HTTP + WebSocket |

**Important:**

- Both servers are **disabled by default** and must be explicitly enabled in Settings.
- Servers listen on **all local interfaces** (`0.0.0.0`). Anyone on the same network can connect when enabled.
- There is **no authentication** on these servers. Do not enable them on untrusted or public networks.
- The HTTP server serves a single-page web UI. The WebSocket server handles real-time communication.
- Disable the servers when not in use.

### Permissions

Textream requests the following macOS permissions:

- **Microphone** — Required for speech recognition and voice-activated features.
- **Speech Recognition** — Required for on-device word tracking.
- **Local Network** — Required when Remote Connection or Director Mode is enabled.

No other permissions are requested or required.

## Recommendations

- Only enable network servers on trusted private networks.
- Disable Remote Connection and Director Mode when not actively in use.
- Keep Textream updated to the latest version via Homebrew or GitHub Releases.

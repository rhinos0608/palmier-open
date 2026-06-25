<div align="center">

# Palmier Open

**AI-native macOS video editor — fully open source.**

<sub><i>Requires macOS 26 (Tahoe) on Apple Silicon</i></sub>

</div>

---

Palmier Open is a community fork of [Palmier Pro](https://github.com/palmier-io/palmier-pro), the excellent video editor built by the Palmier team. This fork removes the backend dependency and adds support for your own AI providers and local models.

All credit for the editor, timeline, MCP server, and Swift-native architecture goes to the [upstream Palmier team](https://github.com/palmier-io/palmier-pro).

### What's different from upstream

- **No backend required.** Removed the Palmier account system, Clerk/Convex auth, and the closed-source generation backend.
- **Bring your own provider.** Configure any OpenAI-compatible API (base URL + key) in Settings → Agent for chat, generation, TTS, upscale, music, and SFX.
- **Local models.** Download and run models on-device via MLX. The app ships a Python MLX server and a model browser that pulls from HuggingFace.
- **Fully open source.** Every line runs on your machine or against your own API keys.

### What's the same

- Full Swift-native video editor with timeline, tracks, trimming, transforms, captions
- MCP server so Claude Code, Codex, Cursor, and Claude Desktop can drive the timeline
- In-app agent panel for chat-based editing
- Generation UI for video, image, music, SFX, and upscale

## MCP server

When the app is open, it exposes an MCP server at `http://127.0.0.1:19789/mcp` via HTTP. To connect:

**Claude Code**
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Cursor**

Go inside the app `Help` → `MCP Instructions` → `Install in Cursor`, or add this to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "palmier-pro": {
      "type": "http",
      "url": "http://127.0.0.1:19789/mcp"
    }
  }
}
```

**Claude Desktop**

Go to `Help` → `MCP Instructions` → `Install in Claude Desktop` for one-click install.

## Development

```bash
swift build
swift run
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

Built by the [Palmier team](https://github.com/palmier-io/palmier-pro) ([Y Combinator S24](https://www.ycombinator.com/companies/palmier)). This fork adapts their work for a fully local, provider-agnostic workflow.

## License

Copyright (C) 2026 Palmier, Inc. Licensed under [GPLv3](LICENSE).

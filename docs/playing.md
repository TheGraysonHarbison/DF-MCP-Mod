# Playing a fort with Claude (development notes)

The player-facing version of this page is the README's Installation, Playing, and Settings sections; the troubleshooting
table Claude itself uses is in `df-skills/skills/fortress-quirks/SKILL.md`. This file keeps what only matters when
developing the channel path.

## Channel log lines

Claude Code writes one line per attempt to its log for the server (`~/.cache/claude-cli-nodejs/<project>/mcp-logs-dfhack/`).
Two lines seen on 2026-10-15 and what they mean:

- `Channel notifications skipped: server did not declare claude/channel capability` together with `"protocolEra":"modern"`:
  Claude Code negotiated MCP revision 2026-07-28, which never registers a channel. The server refuses the `server/discover`
  probe so the classic handshake is used; the line should read `"protocolEra":"legacy"`.
- `Channel notifications skipped: channels not enabled by org policy`: the organization's `channelsEnabled` switch is off.
  An Owner enables it at Organization settings > Claude Code > Channels, then `/mcp` reconnects the server.

## Testing the push path

- `claude-bridge send <text>` in the DFHack console queues a test event that reaches Claude like any other.
- `claude-bridge event <kind> on|off` toggles a kind from the console.
- After server code changes, `/mcp` reconnects the server in the running session.
- Every bridge call pauses the game for a few milliseconds; the event poll runs every two seconds.

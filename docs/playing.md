# Playing a fort with Claude

How to run a session where Claude reacts to the game on its own (Phase 13 onward).

## One-time setup

1. Install the mod and link it: `tools/link-mod.sh <Dwarf Fortress folder>`, then `enable claude-bridge` in the DFHack console.
2. Channels: a claude.ai Team or Enterprise Owner enables Channels under Organization settings > Claude Code. Pro and Max accounts without an organization skip this. Bedrock, Vertex, and Foundry cannot use channels.
3. In `claude-bridge settings`, turn on what Claude may do. The Events tab lists every event kind; mineral discovered, units fighting, and petitions are on by default. The "Send in-game events" permission on the first tab must stay on.

## Each session

1. Load the fort. The mod re-enables itself when the map loads if it was enabled when you saved; `claude-bridge status` shows it.
2. Start Claude Code in this repository with the channel flag (needed while custom channels are in research preview):

   ```
   claude --dangerously-load-development-channels server:dfhack
   ```

   Confirm the warning dialog with "I am using this for local development". The `.mcp.json` here starts the `df-mcp` server, which declares the channel.
3. Ask Claude to `ping`. From then on, every batch of enabled events reaches Claude as a channel message, two quiet seconds or 50 events at a time; Claude handles them when it is idle and queues them while it is busy. The terminal shows one line per batch.

## Without the channel

Everything still works by hand: `list_event_kinds` shows the kinds and queue, `poll_events` reads batches (first without `after_seq`, then with the last sequence received), and `/loop` can drive a polling loop.

## If events never arrive

Claude Code writes one line per attempt to its log for the server (`~/.cache/claude-cli-nodejs/<project>/mcp-logs-dfhack/`). Two lines seen on 2026-10-15 and what they mean:

- `Channel notifications skipped: server did not declare claude/channel capability` together with `"protocolEra":"modern"`: Claude Code negotiated MCP revision 2026-07-28, which never registers a channel. The server now refuses the `server/discover` probe so the classic handshake is used; the line should read `"protocolEra":"legacy"`.
- `Channel notifications skipped: channels not enabled by org policy`: the organization's `channelsEnabled` switch is off. An Owner enables it at Organization settings > Claude Code > Channels, then `/mcp` reconnects the server.

## Good to know

- Every bridge call pauses the game for a few milliseconds; the event poll runs every two seconds.
- Events are dropped silently by Claude Code when the server was not loaded as a channel or the organization blocks channels, and only arrive while the session is open.
- `claude-bridge event <kind> on|off` toggles a kind from the DFHack console.

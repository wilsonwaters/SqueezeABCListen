# Open Questions

Unresolved product/technical decisions and what they block. Resolved items move to the bottom with the answer.

## Open

1. **ABC account login — needed, and how to handle credentials securely?** The plugin must work without
   login. Pending research on what an ABC account unlocks in ABC listen. If worthwhile, credentials/tokens
   would be entered by each user in their own LMS settings page and stored only in LMS prefs — the
   orchestrator/agents never need the stakeholder's real credentials in this repo or session.
   _Blocks: any "My ABC" stream._

2. **Commit authorship convention.** In the SqueezeRTRFM project the stakeholder asked for all commits to be
   authored as Wilson Waters with no tool attribution trailers. No such instruction has been given for this
   repo, so this session's default applies (agent-authored commits with Co-Authored-By trailers; the release
   workflow commits `repo.xml` as `github-actions[bot]`). To confirm with the stakeholder at handoff — easy to
   switch for future commits; rewriting existing history would need their explicit OK.
   _Blocks: nothing._
3. **mediahubaustralia live streams unreachable from the dev container.** `live-radio0N.mediahubaustralia.com`
   returns a Cloudflare 403 to this container's (non-Australian datacenter) egress. ABC's `.pls` files also
   point at `abc.streamguys1.com` HE-AAC Icecast streams, which DO play in the container testbed (verified),
   as do ABC JSON APIs and on-demand MP3s. Whichever live URL family the plugin uses, the stakeholder
   confirms live playback on pi14 (in Australia) at acceptance.
   _Blocks: nothing (streamguys URLs give a container-verifiable live path)._

## Resolved

_(none yet)_

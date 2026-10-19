# Open Questions

Unresolved product/technical decisions and what they block. Resolved items move to the bottom with the answer.

## Open

1. **ABC account login — worth building?** Research: ABC accounts use Gigya (SAP Customer Data Cloud); no audio
   is gated behind login; login only syncs followed programs / listening history / favourite stations across
   ABC apps. **Default decision (pending stakeholder confirmation):** no ABC login in v1 — offer local,
   per-LMS "followed programs" instead, which needs no credentials. ABC-account sync would mean driving an
   undocumented Gigya login flow (fragile, credential handling) for little gain. The stakeholder never needs
   to share credentials with the agents.
   _Blocks: nothing in v1._
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

4. **Live stream quality.** The only live streams LMS can play natively that are reachable from the container
   are ABC's Icecast streams (`abc.streamguys1.com`, HE-AAC 56 kbps). ABC's HLS streams carry 221–246 kbps AAC
   for music stations but LMS 9.x can't play HLS without the third-party PlayHLS plugin. `mediahubaustralia.com`
   streams may be higher quality but are untestable here. **Default decision:** v1 plays the Icecast streams;
   higher-quality live options (HLS via PlayHLS when installed, mediahub when reachable) are planned as an
   optional setting in the live stream and confirmed by the stakeholder on pi14.
   _Blocks: nothing in v1._

## Resolved

_(none yet)_

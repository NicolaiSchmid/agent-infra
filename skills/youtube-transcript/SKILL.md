---
name: youtube-transcript
description: Fetch the transcript (captions) of a YouTube video as plain text by running curl on Forge. Use when the user asks for a YouTube video's transcript, subtitles or captions, or wants to read, summarize or quote a video.
---

# YouTube transcript via Forge

YouTube returns no captions to datacenter IPs such as Atlas. Forge (home IP,
`nschmid10049@forge` over Tailscale) gets them. The method is the one the
Serial Sales transcript app uses (`NicolaiSchmid/serialsales`,
`src/lib/transcripts/youtube.ts`): ask the InnerTube player API as the iOS app
for the caption tracks, then download the track's `timedtext` XML.

Replace `VIDEO_ID` (the `v=` / `youtu.be/` id) and run from Atlas:

```bash
ssh nschmid10049@forge 'bash -s VIDEO_ID' <<'EOF'
v=$1; UA='com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)'
u=$(curl -s -A "$UA" -H 'Content-Type: application/json' -d '{"videoId":"'$v'","context":{"client":{"clientName":"IOS","clientVersion":"20.10.4","deviceModel":"iPhone16,2","hl":"en"}}}' 'https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false' | jq -r '[.captions.playerCaptionsTracklistRenderer.captionTracks[]?] | (map(select(.languageCode|startswith("en")))+.)[0].baseUrl // empty')
[ -n "$u" ] && curl -s -A "$UA" "$u" | python3 -c 'import sys,re,html;print(" ".join(html.unescape(html.unescape(t)).replace("\n"," ") for t in re.findall(r"<text[^>]*>(.*?)</text>",sys.stdin.read(),re.S)))' || echo NO_CAPTIONS
EOF
```

- Already on Forge: drop the `ssh nschmid10049@forge` and run `bash -s VIDEO_ID <<'EOF' … EOF`.
- Prints one line of text. Redirect to a file (`> /srv/agents-state/tmp/VIDEO_ID.txt`) and wrap with `fold -s -w 400` before reading long videos.
- English track preferred, else the first track. For another language change `startswith("en")`.
- Want timestamps or the raw XML? Drop the `| python3 …` part; each `<text start=".." dur="..">` is one cue.
- `NO_CAPTIONS`: the video has no captions, or the client version is stale. Fallback on Forge: `uvx yt-dlp --skip-download --write-auto-subs --sub-langs en --sub-format srv1 -o '%(id)s.%(ext)s' URL`.
- List a channel's latest 15 videos: `curl -s 'https://www.youtube.com/feeds/videos.xml?channel_id=UC…'`. For all of them: `uvx yt-dlp --flat-playlist --print '%(id)s\t%(title)s' https://www.youtube.com/@handle/videos` on Forge.

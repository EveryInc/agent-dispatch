# agent-dispatch

Record your iPhone's screen, talk over it, and an agent does what you asked.

A small Mac app that watches Photos for screen recordings made on your iPhone. When one is you talking over
your screen and asking for something ("reply to this", "look into this", "fix this"), it writes the recording
up and sends it to your agent with a note to watch, listen and act. Recordings where nothing is asked are left
alone.

It runs on an always-on Mac (a Mac mini, say) signed in to the same iCloud Photos library as the phone.

## How it works

A LaunchAgent runs one pass a minute:

1. **Find.** New videos in Photos whose file is an iOS screen recording (`ScreenRecording_…`/`RPReplay_…`, or
   Photos' screen-recording subtype). Only recordings made after install; the library is never changed.
2. **Write up.** The video is copied to `~/Recordings/YYYY-MM-DD-HHMM-iphone/` as a folder an agent can read:
   `recording.mp4`, `audio.m4a`, stills taken whenever the screen changes, the text on screen in each still
   (Vision), a timed transcript (Apple's on-device SpeechTranscriber), `session.json` and `notes.md`.
3. **Judge.** Nothing said → skipped. Otherwise the transcript and on-screen text go to Claude through the
   `claude` command-line tool, which answers whether you are asking for something. It leans towards sending.
   If Claude cannot be reached, a recording you talk through is sent anyway.
4. **Send.** To a [ChatGPT dot](https://learn.chatgpt.com/docs/dots) through Clipshot (below). The send counts
   only once Clipshot's records show the dot accepted the event; otherwise it is retried for about a day.

Everything before the judge runs on the Mac. The judge sends the transcript and on-screen text to Claude; the
send gives the dot the notes, stills and a link to the video.

## What you need

- macOS 26 or later with the Swift command-line tools, and iCloud Photos turned on.
- The [Claude Code](https://claude.com/claude-code) CLI at `~/.local/bin/claude`, signed in.
- On the iPhone, the **microphone turned on** for the recording: long-press the record button in Control
  Center. A silent recording is skipped.
- For the last step, Clipshot: Every's Mac screen recorder, which runs the MCP server a dot subscribes to. It
  is not public yet. Without it everything up to the send still works, and `Sources/Dot.swift` is the one
  file to replace to deliver somewhere else (a webhook, another agent's inbox, a folder an agent watches).

## Using it

```bash
./install.sh install     # build, copy to ~/Applications, start the LaunchAgent
```

```bash
./install.sh status      # is it running, when did it last look, what has it seen
```

```bash
./install.sh uninstall   # stop it
```

The first run asks for access to Photos. Log and state are in `~/Library/Application Support/AgentDispatch/`.

Try the pipeline on any movie, without Photos and without sending anything:

```bash
build/AgentDispatch.app/Contents/MacOS/AgentDispatch process --file movie.mp4 --recordings /tmp/out --support /tmp/sup
```

`--no-model` uses the plain rule instead of Claude; `--send --test` sends the result marked as a test.

Anything that reads Photos has to be started as the app (`open -n -W build/AgentDispatch.app --args list`)
or by the LaunchAgent. Run from a terminal, macOS attributes the Photos request to the terminal instead.

A skipped recording stays in `~/Recordings`, so one the judge got wrong can still be sent by hand.

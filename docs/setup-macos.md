# Setting up bead-loop on your Mac

bead-loop works through a list of small coding tasks ("beads") in your GitHub repos,
using AI models, and opens a pull request for each one it finishes. These steps set it
up on a Mac and connect it to the models on Isaac's server, llm-box. It takes about
twenty minutes, most of it waiting for downloads. You do not need to know how any of it
works. At three points you copy a line into an app called Terminal, and the guide says
exactly what to copy.

## What you need first

- A Mac with an Apple chip (M1 or later).
- A GitHub account that can push to the repo you want the loop to work in.
- From Isaac: an invitation to llm-box on **Tailscale**, and llm-box's address, which
  looks like `http://llm-box.something.ts.net:8100/v1`.

## 1. Connect to llm-box

1. Install **Tailscale** from <https://tailscale.com/download> and open it. A Tailscale
   icon appears at the top right of your screen.
2. Sign in, with any account you like.
3. Open the invitation link Isaac sent you and accept it. llm-box now appears in
   Tailscale's list of machines.

## 2. Run the setup

1. Open **Terminal**: press ⌘ and the space bar together, type `Terminal`, press Return.
2. Copy this whole line, paste it into Terminal, and press Return:

   ```
   curl -fsSL https://raw.githubusercontent.com/imkarrer/bead-loop/main/scripts/setup-macos.sh -o /tmp/setup-bead-loop.sh && bash /tmp/setup-bead-loop.sh
   ```

3. The setup goes through five steps and tells you what each one is doing.
   - **Flox.** If it is not installed, your browser opens its download page. Download
     the installer, open it and follow its steps, then go back to Terminal and press
     Return.
   - **The install.** This builds bead-loop the first time, which takes a few minutes.
     Nothing is asked of you.
   - **GitHub.** Your browser opens GitHub. Terminal shows a short code: copy it into the
     browser page and approve.
   - **Your first repo.** Type the folder of a repo that already has beads in it, or
     press Return to skip and ask Isaac to help you add one later.
   - **The models.** It asks whether to connect to llm-box now. Type `y`, then paste
     the address Isaac sent you. It then asks whether to also run a model on your Mac.
     Say `no` unless Isaac suggested it: it is a 13 GB download.
4. At the end your browser opens **bead-loop's page**, at <http://127.0.0.1:4097>.

## 3. Allow it on your network

The first time the loop talks to llm-box, macOS asks whether **opencode** may find
devices on your local network. Click **Allow**. Until you do, the page shows its tasks
as held, and nothing is lost.

If you clicked Don't Allow by mistake: open **System Settings**, then **Privacy &
Security**, then **Local Network**, and switch opencode on.

## Every day

There is nothing to do. The loop starts by itself when you log in, and the page at
<http://127.0.0.1:4097> shows what it is working on and anything that needs your
answer, under **Needs you**.

- **Pause it:** press **Off** at the top of the page. **Start** turns it back on.
- **Update it:** run the same line from step 2 again.
- **Something looks wrong:** the page shows red checks at the top. Send Isaac the file
  `bead-supervisor.log` from the `Library/Logs/bead-loop` folder in your home folder.
  In Finder, press ⌘⇧G and paste `~/Library/Logs/bead-loop` to get there.

## Removing it

Paste these two lines into Terminal:

```
launchctl bootout gui/$(id -u)/dev.bead-loop.supervisor; launchctl bootout gui/$(id -u)/dev.bead-loop.ui
rm ~/Library/LaunchAgents/dev.bead-loop.*.plist; rm -rf ~/bead-loop
```

## For whoever helps: what the setup did

`scripts/setup-macos.sh` checks out this repo to `~/bead-loop` and runs `install.sh`
in its flox env. That builds the supervisor, links the agents and skills into
`~/.config/opencode`, seeds `~/.config/bead-loop/config.toml`, and starts two launchd
agents. It then runs `gh auth login` and adds the repo to `repos`.
`scripts/configure-models.sh` writes the `llmbox` provider into
`~/.config/opencode/opencode.json`, merged with any other providers, and llm-box's
stages into the loop's config. Optionally it pulls `gpt-oss:20b` into Ollama with a
32k context as the first stage's worker. Any file it replaces is kept beside it as
`.bak-DATE`. Either script can be run again.

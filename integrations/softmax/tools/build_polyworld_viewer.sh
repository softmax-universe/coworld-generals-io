#!/usr/bin/env bash
set -euo pipefail
softmax_source="$(cd -- "$(dirname -- "$0")/.." && pwd)"
root="$(cd "$softmax_source/../.." && pwd)"
output="${1:?expected output bundle directory}"
export POLYWORLD_DEPS="${POLYWORLD_DEPS:-$root/polyworld/.deps}"
export GENERALS_WEB="${GENERALS_WEB:-$root/polyworld/out/softmax-web}"
export EM_CACHE="${EM_CACHE:-$root/polyworld/out/emscripten-cache}"
sh "$root/polyworld/tools/fetch_deps.sh"
while read -r name url revision; do
  directory="$POLYWORLD_DEPS/$name"
  if [[ ! -d "$directory" ]]; then
    git clone --filter=blob:none --no-checkout "$url" "$directory"
    git -C "$directory" checkout --detach "$revision"
  fi
  test "$(git -C "$directory" rev-parse HEAD)" = "$revision"
done < "$softmax_source/replay-dependencies.lock"
cd "$root/polyworld"
nim c --skipParentCfg:on -d:release -d:emscripten -d:replayViewer -d:softmaxReplay \
  --parallelBuild:1 --path:"$softmax_source" \
  --path:"$POLYWORLD_DEPS/spacy/src" --path:"$POLYWORLD_DEPS/noisy/src" \
  src/generals_viewer.nim
python3 - "$GENERALS_WEB" "$output" "$root" "$POLYWORLD_DEPS" <<'PY'
from pathlib import Path
import shutil
import sys

web, output, root, dependencies = (Path(value).resolve() for value in sys.argv[1:])
allowed = (root / 'polyworld/out', root / 'integrations/softmax/dist', root / 'replay-viewer')
if output == root or output in root.parents or (root in output.parents and not any(path in (output, *output.parents) for path in allowed)) or output == web or output in web.parents:
    raise SystemExit('refusing to overwrite replay sources')
if output.exists():
    shutil.rmtree(output)
output.mkdir(parents=True)
html = (web / 'generals.html').read_text()
old = """      const response = await fetch(uri);
      if (!response.ok) throw new Error('Replay download failed (HTTP ' + response.status + ').');
      let bytes = await readReplayStream(response.body);"""
new = """      let bytes;
      if (uri === 'coworld-live') {
        bytes = await new Promise(resolve => {
          const receive = event => {
            if (event.source !== parent || event.origin !== location.origin ||
                event.data?.type !== 'polyworld-replay-data') return;
            window.removeEventListener('message', receive);
            resolve(event.data.replay);
          };
          window.addEventListener('message', receive);
        });
      } else {
        const response = await fetch(uri);
        if (!response.ok) throw new Error('Replay download failed (HTTP ' + response.status + ').');
        bytes = await readReplayStream(response.body);
      }"""
assert html.count(old) == 1, 'upstream replay shell fetch changed'
html = html.replace(old, new)
html = html.replace('      const downloaded = bytes.length;', "      if (bytes.length > MaxReplayBytes) throw new Error('Replay exceeds the 64 MiB limit.');\n      const downloaded = bytes.length;", 1)
html = html.replace('<canvas id="canvas"', '<a id="download-replay" download="generals-polyworld.replay" style="position:fixed;right:12px;bottom:90px;z-index:2;color:white;background:#161922;border:1px solid #666;padding:6px 10px;border-radius:4px;text-decoration:none;font:12px sans-serif">Download replay</a><canvas id="canvas"', 1)
html = html.replace('</head>', '''<style>
@media (max-width: 759px) and (orientation: portrait) {
  #download-replay { top: 4px; bottom: auto !important; right: 8px !important;
    padding: 3px 6px !important; font-size: 11px !important; }
}
</style></head>''', 1)
metadata = """      const ratings = new URLSearchParams(location.hash.slice(1)).get('player_ratings');
      if (ratings !== null) {
        const metadata = JSON.parse(ratings);
        if (typeof metadata.league !== 'string' || typeof metadata.label !== 'string' ||
            !Array.isArray(metadata.players)) throw new Error('Invalid leaderboard metadata.');
        const slots = new Set();
        for (const player of metadata.players) {
          if (!Number.isInteger(player.slot) || player.slot < 0 || player.slot >= 8 ||
              slots.has(player.slot) ||
              (player.score !== null && (typeof player.score !== 'number' || !Number.isFinite(player.score)))) {
            throw new Error('Invalid leaderboard player score.');
          }
          slots.add(player.slot);
        }
        FS.writeFile('/player-ratings.json', new TextEncoder().encode(ratings));
      }
      FS.writeFile('/episode.replay', bytes);
      document.getElementById('download-replay').href = URL.createObjectURL(new Blob([bytes], {type:'application/octet-stream'}));"""
assert html.count("      FS.writeFile('/episode.replay', bytes);") == 1, 'upstream replay staging changed'
html = html.replace("      FS.writeFile('/episode.replay', bytes);", metadata, 1)
(output / 'index.html').write_text(html)
# Live and replay run the same renderer. The live shell accepts only its parent.
live = html.replace("arguments: ['--replay', '/episode.replay']", "arguments: ['--live']")
start = live.index('  preRun: [function() {')
end = live.index('\n};', start)
live = live[:start] + '''  preRun: [],
  pendingLiveSnapshot: null
''' + live[end:]
live = live.replace('<title>Generals Replay</title>', '<title>Polyworld Generals</title>')
live = live.replace('Unable to play this replay.', 'Unable to open this game.')
live = live.replace('Loading replay viewer…', 'Loading Polyworld Generals…')
live = live.replace('Loading Generals replay…', 'Loading Polyworld Generals…')
live = live.replace('<a id="download-replay"', '<a hidden id="download-replay"')
live = live.replace('</script>', '''
window.addEventListener('message', event => {
  if (event.source !== parent || event.origin !== location.origin ||
      event.data?.type !== 'polyworld-live-state') return;
  const encoded = JSON.stringify(event.data.state);
  Module.pendingLiveSnapshot = encoded;
  if (Module.polyworldLiveUpdate) Module.polyworldLiveUpdate(encoded);
});
</script>''', 1)
(output / 'live.html').write_text(live)
for suffix in ('js', 'wasm', 'data'):
    shutil.copyfile(web / f'generals.{suffix}', output / f'generals.{suffix}')
licenses = output / 'licenses'
licenses.mkdir(exist_ok=True)
shutil.copyfile(root / 'polyworld/LICENSE', licenses / 'generals.txt')
for directory in dependencies.iterdir():
    if directory.is_dir():
        for license in directory.glob('LICENSE*'):
            if license.is_file():
                shutil.copyfile(license, licenses / f'{directory.name}-{license.name}')
for license in (root / 'polyworld/assets').rglob('*'):
    if license.is_file() and (license.name.startswith(('LICENSE', 'OFL-')) or license.parent.name == 'licenses'):
        shutil.copyfile(license, licenses / ('assets-' + '-'.join(license.relative_to(root / 'polyworld/assets').parts)))
PY

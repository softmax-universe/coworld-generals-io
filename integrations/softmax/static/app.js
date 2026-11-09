/* Authenticated transport and one action queue for Polyworld live play and replays. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const boardElement = $('board'), renderer = GeneralsTiles(boardElement);
  const params = new URLSearchParams(location.search);
  const polyworld = document.querySelector('meta[name="generals-engine"]')?.content === 'polyworld';
  let nativePlayer, nativePlayerReady;
  let playerNames = [], playerSkills = [], publicArmy = [], publicLand = [], alive = [], chatLines = [];
  let liveStatus = '', finished = false, winner = -1;
  const replayURL = new URLSearchParams(location.hash.slice(1)).get('replay') || params.get('replay');
  const livePrefix = location.pathname.includes('/client/') ? location.pathname.split('/client/')[0] : '';
  let board = null, slot = null, selected = null, half = false, ws = null;
  let currentTurn = -1, sent = true, passTimer = null, replay = null, frameIndex = 0;
  let decodeReplayFrame;
  let playing = true, replayTimer = null, readySent = false, replayLoad = 0;
  let reconnectTimer = null, reconnectAttempt = 0, terminal = false, replayDownload = null;
  let winnerTimer = null, replayEndAt = null;
  const winnerPauseMs = 5000;
  let ruleset = 'classic', playerCount = 2, eliminated = false;
  let chatTurn = -1;
  const privateMessages = [];
  const playerColors = ['red', 'blue', 'green', 'purple', 'orange', 'pink', 'teal', 'maroon'];
  const moves = [[-1,0],[1,0],[0,-1],[0,1]], queue = [];
  let inFlight = null, selectedRoute = null, nextRoute = 0;
  function selectTile(tile, route = null) {
    selected = tile; selectedRoute = tile ? route ?? ++nextRoute : null;
  }
  const sameTile = (a, b) => a && b && a[0] === b[0] && a[1] === b[1];
  const canQueue = () => slot !== null && board && ws?.readyState === WebSocket.OPEN && !replay && !eliminated;
  // Fog obstacles may hide castles or mountains. Plan around them until revealed.
  const blocked = (r, c) => r < 0 || c < 0 || r >= board.type_grid.length ||
    c >= board.type_grid[0].length || [2, 5].includes(board.type_grid[r][c]);
  function blockedMove(action) {
    if (action[0] !== 0) return false;
    const [, r, c, direction] = action, [dr, dc] = moves[direction];
    return blocked(r+dr, c+dc);
  }
  const post = data => { if (parent !== window) parent.postMessage({src: 'coworld-replay', ...data}, '*'); };
  function status(text, error = false) { liveStatus = text; $('status').textContent = text; $('status').classList.toggle('error', error); publishLive(); }
  function ready() { if (!readySent) { readySent = true; setTimeout(() => post({type: 'ready'}), 0); } }
  function fail(message) {
    if (nativePlayer) nativePlayer.style.display = 'none';
    status(message, true); $('cover').hidden = false;
    $('cover-title').textContent = 'Unable to open this match'; $('cover-text').textContent = message;
    post({type: 'error', message});
  }
  function names(players, ratings = null) {
    playerNames = players;
    playerSkills = players.map((_, i) => {
      const score = ratings?.players.find(player => player.slot === i)?.score;
      return score == null ? '—' : score.toFixed(1);
    });
    const matchbar = document.querySelector('.matchbar');
    playerCount = players.length;
    matchbar.classList.toggle('ffa', playerCount > 2);
    document.querySelector('.battlefield').style.setProperty('--player-rows', Math.ceil(playerCount / 2));
    for (let i = 2; i < 8; i++) {
      if (i >= playerCount) { $(`name${i}`)?.closest('.player').remove(); continue; }
      if (!$(`name${i}`)) {
        const card = document.createElement('div'); card.className = `player ${playerColors[i]}`;
        card.innerHTML = `<div><b id="name${i}"></b><small><span id="army${i}">—</span> army <span class="divider">/</span> <span id="land${i}">—</span> land</small></div>`;
        matchbar.append(card);
      }
    }
    players.forEach((name, i) => {
      const label = $(`name${i}`);
      label.closest('.player').style.setProperty('--player-row', Math.floor(i / 2) + 1);
      label.closest('.player').style.setProperty('--player-column', i % 2 === 0 ? 1 : 3);
      if (label.textContent !== name) label.textContent = name;
      if (!$(`skill${i}`)) {
        const skill = document.createElement('small'); skill.id = `skill${i}`;
        label.after(skill);
      }
      const score = ratings?.players.find(player => player.slot === i)?.score;
      $(`skill${i}`).textContent = `★ ${score == null ? '—' : score.toFixed(1)}`;
      $(`skill${i}`).title = ratings ? `${ratings.league} · ${ratings.label} at match start` : 'Skill unavailable';
      if (playerCount > 2 && !$(`kills${i}`)) {
        const badge = document.createElement('small'); badge.id = `kills${i}`;
        label.parentElement.append(badge);
      }
      if (replay) $(`replay-players-${i % 2 === 0 ? 'left' : 'right'}`).append(label.closest('.player'));
    });
    if ($('chat-target').options.length !== players.length + 1) {
      $('chat-target').replaceChildren(new Option('Everyone', '-2'),
        ...players.map((name, i) => new Option(name, String(i))));
    }
    const title = ruleset === 'build_castles' ? 'BUILD YOUR CASTLES' : playerCount > 2 ? `${playerCount}-PLAYER FFA` : 'CLASSIC 1v1';
    $('variant-title').textContent = title; document.title = `Generals · ${title}`;
  }
  function messages(message) {
    if (message.mailbox) {
      privateMessages.push(...message.mailbox.messages.filter(entry => entry.id !== -2).map(entry => entry.text));
      privateMessages.splice(0, Math.max(0, privateMessages.length - 100));
      if (message.mailbox.messages.length && !message.eliminated && message.type === 'observation') {
        ws.send(JSON.stringify({type:'mailbox', count:message.mailbox.messages.length}));
      }
    }
    const publicMessages = [
      ...message.chats.map(chat => ({tick:chat.tick, text:`${message.players[chat.player]}: ${chat.text}`})),
      ...message.events,
    ].sort((a, b) => a.tick - b.tick).slice(-128);
    chatLines = [...publicMessages.map(entry => entry.text), ...privateMessages.map(text => `[Private] ${text}`)];
    $('chat-messages').replaceChildren(...chatLines.map(text => {
        const item = document.createElement('li'); item.textContent = text; return item;
      }));
    $('chat-panel').hidden = false;
    $('chat-form').hidden = slot === null || eliminated;
  }
  $('chat-form').onsubmit = event => {
    event.preventDefault();
    if (!canQueue() || chatTurn === currentTurn || !$('chat-text').value.trim()) return;
    ws.send(JSON.stringify({type:'chat', target:Number($('chat-target').value), text:$('chat-text').value}));
    chatTurn = currentTurn; $('chat-text').value = ''; status('Message queued.');
  };
  function displayTurn(tick) {
    return `${Math.floor(tick / 2)}${tick % 2 ? '.' : ''}`;
  }
  function scoreboard(turn, army, land, eliminatedPlayers = [], kills = []) {
    publicArmy = army; publicLand = land; alive = playerNames.map((_, i) => !eliminatedPlayers[i]);
    $('turn').textContent = displayTurn(turn);
    $('turn').dataset.tick = turn;
    for (let i = 0; i < playerCount; i++) {
      $(`army${i}`).textContent = army[i] ?? '—'; $(`land${i}`).textContent = land[i] ?? '—';
      $(`name${i}`).closest('.player').classList.toggle('eliminated', !!eliminatedPlayers[i]);
      if ($(`kills${i}`)) $(`kills${i}`).textContent = !kills.length ? '' :
        typeof kills[i] === 'boolean' ? (kills[i] ? 'Kill' : 'No kill') : `${kills[i]} kills`;
    }
    $('endgame').textContent = ruleset === 'competition'
      ? (turn >= 800 ? 'DEATHTOUCH ACTIVE · Reach the enemy general to win' : 'Deathtouch from turn 800')
      : ruleset === 'build_castles' ? 'Build castles on your land · Cost starts at 35 army'
      : playerCount > 2 ? 'Capture generals · Last general standing wins' : 'Capture castles to grow your army';
  }
  function buildProblem(r, c) {
    const cost = board.build_cost_grid?.[r]?.[c] || 0;
    if (board.owner_grid[r][c] !== slot+1 || board.type_grid[r][c] !== 1 || cost <= 0) return 'select your own plain land';
    if (board.army_grid[r][c] < cost) return `need ${cost} army to build here (${board.army_grid[r][c]} available)`;
    return null;
  }
  function updateBuildControl() {
    const enabled = ruleset === 'build_castles' && slot !== null && !replay;
    if (enabled && !$('build')) {
      const button = document.createElement('button'); button.id = 'build';
      button.innerHTML = 'Build castle <kbd>B</kbd>'; button.onclick = buildCastle;
      $('play-controls').insertBefore(button, $('pass'));
    } else if (!enabled) $('build')?.remove();
    $('build-hint').hidden = !enabled;
    if (enabled) {
      const cost = selected && board?.build_cost_grid?.[selected[0]]?.[selected[1]];
      $('build').disabled = !canQueue() || !selected || !!buildProblem(...selected);
      $('build-hint').textContent = eliminated ? 'You have been eliminated.' : cost
        ? `Castle cost: ${cost} army · ${board.army_grid[selected[0]][selected[1]]} on this tile`
        : 'Select your own plain land to see its castle cost.';
    }
  }
  function buildCastle() {
    if (!canQueue() || ruleset !== 'build_castles') return;
    if (!selected) { status('Select your own plain land to build a castle.'); return; }
    const problem = buildProblem(...selected);
    if (problem) { status(`Cannot build: ${problem}.`); return; }
    enqueue([2, ...selected, 0, 0]);
  }
  function draw() {
    if (!board) return;
    if (nativePlayer) publishLive();
    else renderer.draw(board, selected, queue.map(item => item.action), inFlight?.action);
    $('queue-count').textContent = `${queue.length} queued`;
    updateBuildControl();
    $('cover').hidden = !$('cover').classList.contains('winner');
    if (!nativePlayer) ready();
  }
  function send(action, automatic = false) {
    if (!ws || ws.readyState !== WebSocket.OPEN || sent || currentTurn < 0) return false;
    ws.send(JSON.stringify({type: 'action', turn: currentTurn, action}));
    sent = true; clearTimeout(passTimer);
    if (!automatic) status(action[0] === 1 ? 'Holding position.' : action[0] === 2 ? 'Castle build submitted.' : 'Move submitted.');
    return true;
  }
  function dispatchQueue() {
    if (!canQueue() || sent) return;
    while (queue.length) {
      const item = queue[0], [kind, r, c] = item.action;
      let reason;
      if (kind !== 1 && board.owner_grid[r][c] !== slot+1) reason = 'the next source tile is no longer yours';
      else if (kind === 0 && blockedMove(item.action)) reason = 'the next move is blocked';
      else if (kind === 0 && board.army_grid[r][c] < 2) reason = 'not enough army to move';
      else if (kind === 2) reason = buildProblem(r, c);
      if (reason) {
        stopRoute(item.route, reason);
        continue;
      }
      if (send(item.action)) inFlight = queue.shift();
      break;
    }
    draw();
  }
  function stopRoute(route, reason) {
    for (let i = queue.length-1; i >= 0; i--) if (queue[i].route === route) queue.splice(i, 1);
    if (inFlight?.route === route) inFlight = null;
    if (selectedRoute === route) selectTile(null);
    draw(); status(`Route stopped: ${reason}.${queue.length ? ' Continuing with the next queued route.' : ' Select a tile to start a new route.'}`);
  }
  function enqueue(action, to = selected) {
    if (!canQueue()) return;
    queue.push({action, from: selected, to, route: selectedRoute ?? ++nextRoute}); selected = to;
    status(`${queue.length} queued · E undoes one, Q clears the queue.`);
    dispatchQueue(); draw();
  }
  function undoMove() {
    const removed = queue.pop();
    if (removed && selectedRoute === removed.route && sameTile(selected, removed.to)) selectTile(removed.from, removed.route);
    draw(); status(removed ? 'Last queued action removed.' : 'No queued moves to undo.');
  }
  function clearQueue() {
    if (queue.length && selectedRoute === queue[queue.length-1].route && sameTile(selected, queue[queue.length-1].to)) {
      selectTile(queue[0].from, queue[0].route);
    }
    queue.length = 0; draw();
    status(inFlight ? 'Queue cleared. The submitted action will finish this turn.' : 'Queue cleared.');
  }
  function move(direction) {
    if (!selected || !canQueue()) return;
    const [r, c] = selected, delta = moves[direction];
    const nr = r+delta[0], nc = c+delta[1];
    if (blocked(nr, nc)) {
      status('Route blocked · Choose a direction around the obstacle.'); return;
    }
    enqueue([0,r,c,direction,half ? 1 : 0], [nr,nc]);
  }
  boardElement.addEventListener('click', event => {
    if (!canQueue()) return;
    const rect = boardElement.getBoundingClientRect();
    const r = Math.floor((event.clientY-rect.top)/rect.height*board.type_grid.length);
    const c = Math.floor((event.clientX-rect.left)/rect.width*board.type_grid[0].length);
    if (r < 0 || c < 0 || r >= board.type_grid.length || c >= board.type_grid[0].length) return;
    if (selected) {
      const dr = r-selected[0], dc = c-selected[1];
      if (Math.abs(dr)+Math.abs(dc) === 1) { move(dr < 0 ? 0 : dr > 0 ? 1 : dc < 0 ? 2 : 3); boardElement.focus(); return; }
    }
    if (board.owner_grid[r][c] === slot+1) selectTile([r,c]);
    draw(); boardElement.focus();
  });
  document.querySelectorAll('[data-direction]').forEach(button => {
    button.onclick = () => move(Number(button.dataset.direction));
  });
  $('split').onclick = () => { half = !half; $('split').setAttribute('aria-pressed', String(half)); draw(); };
  $('pass').onclick = () => enqueue([1,0,0,0,0]);
  $('surrender').onclick = () => {
    if (!canQueue()) return;
    ws.send(JSON.stringify({type:'surrender'}));
    queue.length = 0; clearTimeout(passTimer); sent = true;
    $('surrender').disabled = true;
    status('Surrender submitted. Your territory remains capturable for 50 ticks.');
  };
  $('deselect').onclick = () => { selectTile(null); draw(); status('Selection cleared.'); };
  $('undo').onclick = undoMove;
  $('clear').onclick = clearQueue;
  // Keep keyboard play working after clicking a control with the mouse.
  $('play-controls').addEventListener('click', event => { if (event.target.closest('button')) boardElement.focus(); });
  document.addEventListener('keydown', event => {
    if (slot === null || event.ctrlKey || event.metaKey || event.altKey ||
        event.target.matches('input, textarea, select, button') || event.target.isContentEditable) return;
    const key = event.key.toLowerCase();
    const keys = {arrowup:0, w:0, arrowdown:1, s:1, arrowleft:2, a:2, arrowright:3, d:3};
    if (key in keys) { event.preventDefault(); move(keys[key]); }
    else if (key === 'h') $('split').click();
    else if (key === 'b' && ruleset === 'build_castles') { event.preventDefault(); buildCastle(); }
    else if (key === 'e') { event.preventDefault(); undoMove(); }
    else if (key === 'q') { event.preventDefault(); clearQueue(); }
    else if (key === ' ') { event.preventDefault(); $('deselect').click(); }
  });
  function outcome(result) {
    const text = result.winner < 0 ? 'Draw' : `${$('name'+result.winner).textContent} wins`;
    const reasons = {general_capture:'general captured', turn_limit:'turn limit reached', forfeit:'surrender', idle_limit:'inactivity adjudication', double_forfeit:'remaining players timed out'};
    return `${text} · ${reasons[result.reason] || result.reason}`;
  }
  function showWinner(result) {
    const text = result.winner < 0 ? 'The game is a draw.' : `${$('name'+result.winner).textContent} wins the game!`;
    $('cover').hidden = false; $('cover').classList.add('winner');
    $('cover-title').textContent = text; $('cover-text').textContent = '';
  }
  function finishMatch(result, recording) {
    if (winnerTimer !== null || terminal) return;
    terminal = true; sent = true; finished = true; winner = result.winner;
    clearTimeout(reconnectTimer); clearTimeout(passTimer);
    $('mode').textContent = 'FINISHED'; $('play-controls').hidden = true;
    status(outcome(result)); showWinner(result);
    winnerTimer = setTimeout(() => {
      winnerTimer = null;
      loadReplay(recording).catch(err => fail(err.message));
    }, winnerPauseMs);
  }
  function showReplayFrame() {
    const frame = decodeReplayFrame(frameIndex), perspective = $('perspective').value;
    board = frame;
    if (perspective !== 'all') {
      const owner = Number(perspective) + 1;
      const visible = frame.owner_grid.map((row, r) => row.map((_, c) => {
        for (let dr = -1; dr <= 1; dr++) for (let dc = -1; dc <= 1; dc++) {
          if (frame.owner_grid[r+dr]?.[c+dc] === owner) return true;
        }
        return false;
      }));
      board = {...frame,
        type_grid: frame.type_grid.map((row, r) => row.map((kind, c) => visible[r][c] ? kind : [2,3].includes(kind) ? 5 : 0)),
        owner_grid: frame.owner_grid.map((row, r) => row.map((value, c) => visible[r][c] ? value : 0)),
        army_grid: frame.army_grid.map((row, r) => row.map((value, c) => visible[r][c] ? value : 0)),
      };
    }
    scoreboard(board.turn, board.army, board.land, board.eliminated, board.kills); draw();
    $('seek').value = frameIndex;
    status(`${outcome(replay.result)} · Frame ${frameIndex+1} of ${replay.frames.length}`);
    if (frameIndex === replay.frames.length - 1) {
      if (replayEndAt === null) replayEndAt = performance.now();
      showWinner(replay.result);
    } else {
      replayEndAt = null;
      $('cover').hidden = true; $('cover').classList.remove('winner');
    }
  }
  function resetReplayTimer() {
    clearInterval(replayTimer);
    replayTimer = setInterval(() => {
      if (playing && replay) {
        if (frameIndex === replay.frames.length - 1 &&
            performance.now() - replayEndAt < winnerPauseMs) return;
        frameIndex = (frameIndex+1) % replay.frames.length; showReplayFrame();
      }
    }, 1000 / Number($('speed').value));
  }
  $('pause').onclick = () => { playing = !playing; $('pause').textContent = playing ? 'Pause' : 'Play'; };
  $('restart').onclick = () => { frameIndex = 0; showReplayFrame(); };
  $('seek').oninput = () => { frameIndex = Number($('seek').value); showReplayFrame(); };
  $('speed').onchange = resetReplayTimer;
  $('perspective').onchange = showReplayFrame;
  let nativeReplay, nativeReplayReady, nativeReplayVisible = false;
  function prepareNativeReplay() {
    if (nativeReplayReady) return nativeReplayReady;
    nativeReplay = document.createElement('iframe');
    nativeReplay.id = 'polyworld-replay'; nativeReplay.title = 'Polyworld Generals replay';
    nativeReplay.style.cssText = 'display:none;position:fixed;inset:0;width:100%;height:100%;border:0;z-index:100';
    nativeReplayReady = new Promise(resolve => {
      window.addEventListener('message', event => {
        if (event.source !== nativeReplay.contentWindow || event.origin !== location.origin || event.data?.src !== 'coworld-replay') return;
        if (event.data.type === 'phase' && event.data.phase === 'bundle_ready') resolve();
        if (event.data.type === 'error') fail(event.data.message);
        if (nativeReplayVisible) post(event.data);
      });
    });
    nativeReplay.src = livePrefix + '/client/polyworld/index.html#replay=coworld-live';
    document.body.append(nativeReplay);
    return nativeReplayReady;
  }
  async function loadReplay(source) {
    clearTimeout(winnerTimer); winnerTimer = null; replayEndAt = null;
    $('cover').classList.remove('winner');
    $('chat-panel').hidden = true;
    document.body.classList.add('replay');
    $('replay-controls').prepend(document.querySelector('.clock'));
    $('replay-left').append($('replay-controls'));
    $('replay-right').append($('match-result'));
    $('replay-timeline').append($('seek'));
    $('replay-timeline').hidden = true;
    $('launch').hidden = true;
    document.querySelector('.matchbar').hidden = false;
    document.querySelector('.arena').hidden = false;
    $('match-result').hidden = true;
    const load = ++replayLoad;
    terminal = true; clearTimeout(reconnectTimer);
    if (ws) ws.close();
    clearInterval(replayTimer); clearTimeout(passTimer);
    replay = null; board = null; readySent = false; slot = null; sent = true;
    eliminated = false; updateBuildControl();
    queue.length = 0; inFlight = null; selectTile(null);
    $('play-controls').hidden = true;
    $('mode').textContent = 'LOADING'; $('replay-controls').hidden = true;
    $('cover').hidden = false; $('cover-title').textContent = 'Loading the replay';
    $('cover-text').textContent = 'Reconstructing the battlefield.';
    post({type:'loading'}); post({type:'phase', phase:'replay_fetch_start'});
    let data = source;
    if (source?.encoding === 'gzip+base64') {
      const bytes = Uint8Array.from(atob(source.data), value => value.charCodeAt(0));
      data = new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
    } else if (typeof source === 'string') {
      const response = await fetch(source, {credentials:'omit'});
      if (!response.ok) throw new Error(`Replay could not be loaded (${response.status}).`);
      let bytes = new Uint8Array(await response.arrayBuffer());
      const compressed = bytes[0] === 0x1f && bytes[1] === 0x8b;
      post({type:'phase', phase:'replay_fetch_end', bytes:bytes.length, compressed});
      if (compressed) bytes = new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
      data = bytes;
    }
    if (load !== replayLoad) return;
    if (data instanceof Uint8Array && new TextDecoder().decode(data.subarray(0, 'POLYWORLDREPLAY'.length)) === 'POLYWORLDREPLAY') {
      await prepareNativeReplay();
      if (nativePlayer) nativePlayer.style.display = 'none';
      nativeReplayVisible = true;
      nativeReplay.style.display = 'block';
      nativeReplay.contentWindow.postMessage({type:'polyworld-replay-data', replay:data}, location.origin);
      return;
    }
    if (data instanceof Uint8Array) data = JSON.parse(new TextDecoder().decode(data));
    decodeReplayFrame = GeneralsReplay(data);
    replay = data; ruleset = data.ruleset || 'competition'; slot = null; selected = null; clearTimeout(passTimer);
    names(data.players); $('mode').textContent = 'REPLAY';
    $('perspective').replaceChildren(new Option('Full map', 'all'),
      ...data.players.map((name, i) => new Option(name, String(i))));
    $('result-title').textContent = outcome(data.result);
    $('result-detail').textContent = `${displayTurn(data.frames[data.frames.length-1].turn)} turns · ${data.frames[data.frames.length-1].turn} ticks · ${data.players.length} players` + (data.result.placements ? ' · Survival place: ' + data.result.placements.join(', ') : '');
    $('match-result').hidden = false;
    if (replayDownload) URL.revokeObjectURL(replayDownload);
    replayDownload = URL.createObjectURL(new Blob([JSON.stringify(data)], {type:'application/json'}));
    $('download-replay').href = replayDownload;
    $('play-controls').hidden = true; $('replay-controls').hidden = false; $('seek').max = data.frames.length-1;
    $('replay-timeline').hidden = false;
    post({type:'phase', phase:'replay_parsed'});
    readySent = false; frameIndex = 0; showReplayFrame(); resetReplayTimer();
  }
  function observe(message) {
    const firstTurn = currentTurn < 0;
    $('surrender').hidden = message.players.length < 3;
    const previousMove = inFlight;
    slot = message.slot; currentTurn = message.turn; sent = false; inFlight = null;
    ruleset = message.ruleset || ruleset; eliminated = !!message.eliminated; names(message.players, message.player_ratings);
    messages(message);
    if (playerCount > 2 && !message.visible_owner_grid) throw new Error('This multiplayer observation is missing visible owner identities.');
    const owners = message.visible_owner_grid || message.owner_grid.map(row => row.map(o => o === 0 ? 0 : o === 1 ? slot+1 : 2-slot));
    board = {...message, owner_grid: owners};
    // A failed step invalidates its route, but independently selected armies
    // keep their plans and can take over this turn.
    const failedMove = previousMove?.action[0] === 0 &&
      (message.last_move_executed === false || owners[previousMove.to[0]][previousMove.to[1]] !== slot+1);
    const failedBuild = previousMove?.action[0] === 2 && message.last_build_executed === false;
    const obstructedRoutes = new Set(queue.filter(item => blockedMove(item.action)).map(item => item.route));
    if (!queue.length && selected && owners[selected[0]][selected[1]] !== slot+1) selectTile(null);
    const army = message.public_scores?.army || [], land = message.public_scores?.land || [];
    if (!message.public_scores && playerCount === 2) {
      army[slot] = message.my_army; army[1-slot] = message.opp_army;
      land[slot] = message.my_land; land[1-slot] = message.opp_land;
    }
    scoreboard(message.turn, army, land, message.public_scores?.eliminated, message.public_scores?.has_kill); draw();
    if (message.afk_warning) status('Expand to 11 land, own a city, or reach an opponent before tick 121 to avoid inactivity elimination.');
    else if (firstTurn) status('Select a tile and queue moves with the arrow keys.');
    clearTimeout(passTimer);
    if (eliminated) {
      queue.length = 0; selectTile(null); sent = true; draw();
      $('play-controls').hidden = true;
      status('You have been eliminated. Follow the scores until the match ends, then watch the full replay.');
      return;
    }
    // The deadline starts on the server, before either leg of the proxy trip.
    // Queue inputs made after this pass will execute on the following tick.
    passTimer = setTimeout(() => send([1,0,0,0,0], true), Math.min(50, message.turn_timeout_seconds * 200));
    if (failedMove) stopRoute(previousMove.route, 'the previous move did not reach its destination');
    if (failedBuild) stopRoute(previousMove.route, 'the castle could not be built');
    else if (previousMove?.action[0] === 2 && message.last_build_executed === true) status('Castle built.');
    for (const route of obstructedRoutes) stopRoute(route, 'an obstacle blocks the route');
    dispatchQueue();
  }
  function publishLive() {
    if (!nativePlayer || !board || slot === null) return;
    const width = board.type_grid[0].length;
    const index = tile => tile ? tile[0] * width + tile[1] : -1;
    const orders = [...(inFlight ? [inFlight] : []), ...queue].filter(item => item.action[0] === 0).map(item => {
      const [, r, c, direction, split] = item.action, [dr, dc] = moves[direction];
      return {source:r * width + c, target:(r + dr) * width + c + dc, half:!!split};
    });
    nativePlayer.contentWindow.postMessage({type:'polyworld-live-state', state:{
      width, height:board.type_grid.length, slot, tick:currentTurn,
      types:board.type_grid, owners:board.owner_grid, armies:board.army_grid,
      names:playerNames, skills:playerSkills, army:publicArmy, land:publicLand,
      alive, selected:index(selected), half, orders, messages:chatLines,
      status:liveStatus, ruleset, finished, winner,
    }}, location.origin);
  }
  function prepareNativePlayer() {
    if (nativePlayerReady) return nativePlayerReady;
    nativePlayer = document.createElement('iframe');
    nativePlayer.id = 'polyworld-player'; nativePlayer.title = 'Polyworld Generals live game';
    nativePlayer.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;border:0;z-index:99';
    nativePlayerReady = new Promise(resolve => {
      window.addEventListener('message', event => {
        if (event.source !== nativePlayer.contentWindow || event.origin !== location.origin) return;
        if (event.data?.src === 'coworld-replay') {
          if (event.data.type === 'phase' && event.data.phase === 'live_ready') resolve();
          if (event.data.type === 'error') fail(event.data.message);
          if (event.data.type === 'ready') { ready(); nativePlayer.contentWindow.focus(); }
          return;
        }
        if (event.data?.type !== 'polyworld-live-input' || !canQueue()) return;
        const input = event.data.input;
        if (input.kind === 'move') {
          const savedHalf = half; half ||= input.half; move(input.value); half = savedHalf; draw();
        } else if (input.kind === 'tile') {
          const width = board.type_grid[0].length;
          const r = Math.floor(input.value / width), c = input.value % width;
          if (selected) {
            const dr = r-selected[0], dc = c-selected[1];
            if (Math.abs(dr)+Math.abs(dc) === 1) { move(dr < 0 ? 0 : dr > 0 ? 1 : dc < 0 ? 2 : 3); return; }
          }
          if (board.owner_grid[r][c] === slot+1) selectTile([r,c]);
          draw();
        } else if (input.kind === 'general') {
          board.type_grid.forEach((row, r) => row.forEach((kind, c) => {
            if (kind === 4 && board.owner_grid[r][c] === slot+1) selectTile([r,c]);
          })); draw();
        } else if (input.kind === 'chat') {
          $('chat-target').value = String(input.value);
          $('chat-text').value = input.text; $('chat-form').requestSubmit();
        } else {
          const controls = {split:'split', undo:'undo', clear:'clear', build:'build',
            deselect:'deselect', pass:'pass', surrender:'surrender'};
          const id = controls[input.kind];
          if (id) $(id)?.click();
        }
      });
    });
    nativePlayer.src = livePrefix + '/client/polyworld/live.html';
    document.body.append(nativePlayer);
    return nativePlayerReady;
  }
  async function connectLive() {
    if (polyworld) {
      const preparation = [prepareNativeReplay()];
      if (location.pathname.endsWith('/client/player')) preparation.push(prepareNativePlayer());
      await Promise.all(preparation);
    }
    const isPlayer = location.pathname.endsWith('/client/player');
    const route = livePrefix + (isPlayer ? '/player' : '/global');
    const address = params.get('address');
    let url;
    if (address !== null) {
      try {
        url = new URL(address);
        if (!['ws:', 'wss:'].includes(url.protocol) || url.host !== location.host || url.pathname !== route) {
          throw new Error('Invalid connection address');
        }
      } catch (_) { fail('Invalid connection address. Reopen this game from its lobby.'); return; }
    } else {
      url = new URL(route, location.href); url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      if (isPlayer) { url.searchParams.set('slot', params.get('slot') || ''); url.searchParams.set('token', params.get('token') || ''); }
    }
    // The live HTTP proxy can disappear as soon as results are saved.
    // Receive the recording on this established socket instead of fetching it.
    ws = new WebSocket(url);
    ws.onopen = () => {
      ws.send(JSON.stringify({type:'subscribe', replay:true}));
      $('mode').textContent = isPlayer ? 'PLAYER' : 'LIVE';
      status(isPlayer && board ? 'Reconnected. Queued moves cleared.' : 'Waiting for all players.');
    };
    ws.onmessage = event => {
      try {
        const message = JSON.parse(event.data);
        reconnectAttempt = 0;
        if (message.type === 'hello') {
          ruleset = message.ruleset || 'classic';
          slot = message.slot; names(message.players, message.player_ratings); $('play-controls').hidden = false;
          updateBuildControl();
        } else if (message.type === 'observation') observe(message);
        else if (message.type === 'global') {
          ruleset = message.ruleset || ruleset;
          names(message.players, message.player_ratings); scoreboard(message.turn, message.army, message.land, message.eliminated, message.has_kill);
          messages(message);
          if (message.phase === 'finished') { finishMatch(message.result, message.replay); }
          else {
            if (message.phase === 'failed') terminal = true;
            $('cover-title').textContent = message.phase === 'waiting' ? 'Waiting for the generals' : message.phase === 'failed' ? 'Match could not finish' : 'The battle is underway';
            $('cover-text').textContent = 'The live map stays hidden to protect fog of war. Watch the score here, then explore the full replay.';
            status(message.phase === 'waiting' ? 'Waiting for all players.' : message.phase === 'failed' ? 'The episode failed. Check the game logs.' : 'Live score · Board revealed after the match.'); ready();
          }
        } else if (message.type === 'final') {
          finishMatch(message.result, message.replay);
        } else if (message.type === 'error') {
          if (inFlight) stopRoute(inFlight.route, message.message);
          else status(message.message, true);
        }
        else if (message.type === 'failure') { terminal = true; fail('The episode could not complete.'); }
      } catch (err) { fail(err.message); }
    };
    ws.onerror = () => status('Connection failed. Check the player link and game server.', true);
    ws.onclose = event => {
      clearTimeout(passTimer); queue.length = 0; inFlight = null; sent = true; draw();
      if (terminal) return;
      $('mode').textContent = 'RECONNECTING';
      if (!navigator.onLine) {
        status('You are offline. Reconnecting when your connection returns.'); return;
      }
      if ([1008, 4001, 4003].includes(event.code)) {
        terminal = true; fail('This seat is unavailable. Reopen the game from its lobby.'); return;
      }
      if (reconnectAttempt >= 6) {
        fail('Could not reconnect. Reopen the game from its lobby.'); return;
      }
      const delay = Math.min(500 * 2 ** reconnectAttempt++, 4000);
      $('mode').textContent = 'RECONNECTING';
      status('Connection interrupted. Reconnecting; queued moves have been cleared.');
      reconnectTimer = setTimeout(connectLive, delay);
    };
  }
  window.addEventListener('offline', () => {
    if (!terminal && ws) { clearTimeout(reconnectTimer); ws.close(); }
  });
  window.addEventListener('online', () => {
    if (!terminal && ws?.readyState === WebSocket.CLOSED) {
      clearTimeout(reconnectTimer); reconnectAttempt = 0; connectLive();
    }
  });
  window.addEventListener('pagehide', () => {
    terminal = true; clearTimeout(reconnectTimer); clearTimeout(passTimer); clearInterval(replayTimer);
    clearTimeout(winnerTimer);
    if (ws) ws.close();
    if (replayDownload) URL.revokeObjectURL(replayDownload);
  });
  new ResizeObserver(draw).observe(boardElement.parentElement);
  window.addEventListener('hashchange', () => {
    const url = new URLSearchParams(location.hash.slice(1)).get('replay');
    if (url) loadReplay(url).catch(err => fail(err.message));
  });
  if (replayURL) loadReplay(replayURL).catch(err => fail(err.message));
  else if (location.pathname.endsWith('/client/replay')) loadReplay(livePrefix+'/client/replay.data').catch(err => fail(err.message));
  else if (['/client/player', '/client/global'].some(route => location.pathname.endsWith(route))) connectLive();
  else {
    $('launch').hidden = false;
    document.querySelector('.matchbar').hidden = true;
    document.querySelector('.arena').hidden = true;
    $('mode').textContent = 'WELCOME';
    status('One battlefield for people and bots.');
  }
  $('replay-file').onchange = async () => {
    const [file] = $('replay-file').files;
    if (!file) return;
    const url = URL.createObjectURL(file);
    await loadReplay(url).catch(err => fail(err.message));
    URL.revokeObjectURL(url);
  };
})();

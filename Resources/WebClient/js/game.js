// === State ===
const state = {
  playerId: null, playerName: '', mySeat: -1, roomId: 'default',
  inGame: false, isReady: false, isHost: false,
  myHand: [], skillCards: [], selectedCards: new Set(),
  gamePhase: '', currentTurn: -1, lastHand: null, roundActions: {},
  winners: [], tributeState: null, skipStatus: [],
  newCardIds: new Set(), roomPlayers: [],
};

// Card suit/rank helpers
const SUITS = { 0: '♠', 1: '♥', 2: '♣', 3: '♦', 4: '🃏' };
const SUIT_NAMES = {0:'spades',1:'hearts',2:'clubs',3:'diamonds',4:'joker'};
const RANKS = {2:'2',3:'3',4:'4',5:'5',6:'6',7:'7',8:'8',9:'9',10:'10',11:'J',12:'Q',13:'K',14:'A',15:'🃏',16:'👑'};
const RED_SUITS = new Set([1, 3]); // hearts, diamonds

function cardKey(c) { return (c && c.id) ? c.id : JSON.stringify(c); }
function isRed(c) { return RED_SUITS.has(c ? c.suit : -1) || (c && c.rank >= 15); }
function isWildCard(c) { return c && c.isWild; }
function cardDesc(c) {
  if (!c) return '?';
  if (c.rank >= 15) return RANKS[c.rank];
  return SUITS[c.suit] + RANKS[c.rank];
}

// === API ===
const API = {
  base() { return ''; },
  async post(url, body) {
    const resp = await fetch(url, { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
    return resp.json();
  },
  join(name) {
    const id = 'player-' + Math.random().toString(36).slice(2, 10);
    state.playerId = id;
    state.playerName = name;
    return API.post('/api/join?' + new URLSearchParams({playerId: id}), { playerName: name, roomId: state.roomId });
  },
  act(type, payload = {}) {
    return API.post('/api/action', { playerId: state.playerId, type, payload });
  },
};

// === SSE ===
let sseSource = null;
function connectSSE() {
  if (sseSource) sseSource.close();
  const url = '/api/events?playerId=' + state.playerId;
  sseSource = new EventSource(url);
  sseSource.addEventListener('roomState', e => onRoomState(JSON.parse(e.data)));
  sseSource.addEventListener('gameState', e => onGameState(JSON.parse(e.data)));
  sseSource.addEventListener('matchStarted', e => { console.log('Match started'); });
  sseSource.addEventListener('matchOver', e => onMatchOver(JSON.parse(e.data)));
  sseSource.addEventListener('gameOver', e => onGameOver(JSON.parse(e.data)));
  sseSource.addEventListener('chatMessage', e => onChatMessage(JSON.parse(e.data)));
  sseSource.addEventListener('gameTerminated', e => backToLobby());
  sseSource.addEventListener('error', e => {
    try { const d = JSON.parse(e.data); showToast(d.message || 'Error'); } catch(_) {}
  });
  sseSource.onerror = () => { if (!state.inGame) { setTimeout(connectSSE, 3000); } };
}

// === UI: Lobby ===
function onRoomState(data) {
  if (state.inGame) return; // Never reset game view from roomState
  state.roomPlayers = data.players || [];
  document.getElementById('lobby').classList.add('active');
  document.getElementById('game').classList.remove('active');
  document.getElementById('lobby').classList.add('active');
  document.getElementById('game').classList.remove('active');
  document.getElementById('roomInfo').style.display = 'block';
  document.getElementById('chatBox').style.display = 'block';

  const isHost = state.roomPlayers[0] && state.roomPlayers[0].id === state.playerId;
  state.isHost = isHost;
  document.getElementById('startBtn').style.display = isHost ? 'inline-block' : 'none';

  // Mode buttons
  if (isHost) {
    const mode = data.gameMode || 'Normal';
    document.getElementById('modeNormal').classList.toggle('active', mode === 'Normal');
    document.getElementById('modeSkill').classList.toggle('active', mode === 'Skill');
  }

  renderSeats();
}

function renderSeats() {
  const grid = document.getElementById('seatGrid');
  grid.innerHTML = '';
  for (let i = 0; i < 4; i++) {
    const p = state.roomPlayers[i];
    const div = document.createElement('div');
    div.className = 'seat ' + (p ? (p.id === state.playerId ? 'you occupied' : 'occupied') : 'empty');
    if (p) {
      const status = p.isReady ? '<span class="seat-status ready">Ready</span>' : '<span class="seat-status">Waiting</span>';
      div.innerHTML = '<div class="seat-name">' + p.name + (p.isBot ? ' 🤖' : '') + '</div>' + status;
      if (!p.isBot && p.id !== state.playerId && !state.inGame && state.roomPlayers[i] === p) {
        div.style.cursor = 'pointer';
        div.title = 'Switch seat';
        div.onclick = () => API.act('switchSeat', { targetSeat: i });
      }
    } else {
      div.innerHTML = '<div class="seat-name">空位</div>';
      div.style.cursor = 'pointer';
      div.title = 'Take seat';
      div.onclick = () => API.act('switchSeat', { targetSeat: i });
    }
    grid.appendChild(div);
  }

  // Ready button
  const me = state.roomPlayers.find(p => p && p.id === state.playerId);
  if (me) {
    state.isReady = me.isReady;
    if (me.seatIndex !== undefined) state.mySeat = me.seatIndex;
  }
  document.getElementById('readyBtn').textContent = state.isReady ? '取消准备' : '准备';
}

// === UI: Game ===
function onGameState(data) {
  if (data.playerId !== state.playerId) return;
  state.inGame = true;
  state.myHand = data.ownHand || [];
  state.skillCards = data.skillCards || [];
  state.gamePhase = data.phase || '';
  state.currentTurn = data.currentTurn;
  state.lastHand = data.lastHand;
  state.winners = data.winners || [];
  state.tributeState = data.tributeState;
  state.skipStatus = data.skipNextTurn || [];
  state.newCardIds = new Set(data.newCardIds || []);
  state.mySeat = data.seatIndex;

  if (data.roundActions) {
    const ra = {};
    Object.entries(data.roundActions).forEach(([k, v]) => { ra[parseInt(k)] = v; });
    state.roundActions = ra;
  }

  document.getElementById('lobby').classList.remove('active');
  document.getElementById('game').classList.add('active');

  renderGameBoard(data);
  renderMyHand();
  renderSkillBar();
  renderHistory(data.history || []);
  updateGameHeader(data);
}

function updateGameHeader(data) {
  document.getElementById('roundLabel').textContent = '第' + (data.currentRound || 1) + '局';
  document.getElementById('levelLabel').textContent = '打' + (data.level || 2);
  const teamLevels = data.teamLevels || {};
  document.getElementById('teamLabel').textContent =
    'Team0:' + (teamLevels['0']||2) + ' Team1:' + (teamLevels['1']||2);
}

function renderGameBoard(data) {
  // Update player areas
  for (let i = 0; i < 4; i++) {
    const tag = document.getElementById('tag-player' + i);
    const count = document.getElementById('count-player' + i);
    const area = document.getElementById('area-player' + i);
    const player = state.roomPlayers[i];
    if (tag) tag.textContent = player ? player.name : ('Bot ' + i);
    if (count) {
      if (i === state.mySeat) {
        count.textContent = state.myHand.length + ' cards';
      } else {
        count.textContent = (data.otherHandSizes && data.otherHandSizes[i]) ? data.otherHandSizes[i] + ' cards' : '';
      }
    }
    if (area) {
      area.classList.toggle('current', i === state.currentTurn && state.gamePhase === 'playing');
      area.classList.toggle('won', state.winners.includes(i));
      // Show ranking label
      const rankIdx = state.winners.indexOf(i);
      const ranks = ['头游','二游','三游','末游'];
      if (rankIdx >= 0 && tag) {
        tag.textContent = (state.roomPlayers[i] ? state.roomPlayers[i].name : ('Bot '+i)) + ' [' + ranks[rankIdx] + ']';
      }
    }
  }

  // Play zone
  const pz = document.getElementById('lastPlayInfo');
  if (state.lastHand && state.lastHand.hand) {
    const h = state.lastHand.hand;
    const typeNames = {Single:'单张',Pair:'对子',Trips:'三张',TripsWithPair:'三带二',Straight:'顺子',Tube:'钢板',Plate:'木板',Bomb:'炸弹',StraightFlush:'同花顺',FourKings:'天王炸'};
    const typeName = typeNames[h.type] || h.type;
    const fromPlayer = state.lastHand.playerIndex !== undefined
      ? (state.roomPlayers[state.lastHand.playerIndex] || {}).name || ('Bot ' + state.lastHand.playerIndex) : '?';
    pz.innerHTML = '<div>' + fromPlayer + ' 出了 <b>' + typeName + '</b></div>';
    // Show cards
    const cd = document.createElement('div');
    cd.className = 'played-cards';
    (h.cards || []).forEach(c => {
      const el = document.createElement('span');
      el.className = 'small-card' + (isRed(c) ? ' red' : '');
      if (c.rank >= 15) el.className += ' joker';
      el.textContent = cardDesc(c);
      cd.appendChild(el);
    });
    pz.appendChild(cd);
  } else {
    pz.innerHTML = state.gamePhase === 'tribute' ? '进贡阶段' : state.gamePhase === 'returnTribute' ? '还贡阶段' : '自由出牌';
  }

  // Tribute UI
  const tribUI = document.getElementById('tributeUI');
  if (state.gamePhase === 'tribute' || state.gamePhase === 'returnTribute') {
    tribUI.style.display = 'flex';
    const items = state.gamePhase === 'tribute' ? (state.tributeState || {}).pendingTributes : (state.tributeState || {}).pendingReturns;
    if (!items) { tribUI.style.display = 'none'; return; }
    const myItem = items && items.find(t => t.from === state.mySeat && !t.card);
    if (myItem) {
      tribUI.innerHTML = '<div style="font-size:13px;color:#ffd700;">请选择一张牌' + (state.gamePhase === 'tribute' ? '进贡' : '还贡') + '</div>' +
        state.myHand.map(c =>
          '<span class="tribute-card small-card' + (isRed(c)?' red':'') + '" data-id="' + c.id + '" onclick="selectTribute(\'' + c.id + '\')">' + cardDesc(c) + '</span>'
        ).join('');
    } else {
      tribUI.innerHTML = '<div style="font-size:13px;">等待其他玩家...</div>';
    }
  } else {
    tribUI.style.display = 'none';
  }

  // Action bar
  const isMyTurn = state.currentTurn === state.mySeat && state.gamePhase === 'playing';
  // Bright pulsing button when it's your turn
  const pb = document.getElementById('playBtn');
  if (isMyTurn) { pb.classList.add('my-turn'); } else { pb.classList.remove('my-turn'); }
  // Force enable for debugging
  document.getElementById('playBtn').disabled = false;
  document.getElementById('passBtn').disabled = false;
  const turnHint = document.getElementById('turnHint');
  if (turnHint) turnHint.textContent = isMyTurn ? '▶ 轮到你出牌' : (state.gamePhase==='playing' ? '等待其他玩家...' : '');
  document.getElementById('passBtn').disabled = !isMyTurn;
  document.getElementById('hintBtn').style.display = isMyTurn ? 'inline-block' : 'none';
}

function renderMyHand() {
  const container = document.getElementById('myHand');
  container.innerHTML = '';
  state.myHand.forEach(c => {
    const el = document.createElement('span');
    const isSel = state.selectedCards.has(c.id);
    el.className = 'card' + (isRed(c) ? ' red' : '') + (isSel ? ' selected' : '') + (isWildCard(c) ? ' wild' : '') + (state.newCardIds.has(c.id) ? ' new-highlight' : '');
    if (c.rank >= 15) el.className += ' joker';
    el.innerHTML = '<span class="suit-top">' + SUITS[c.suit] + '</span><span class="rank">' + RANKS[c.rank] + '</span>';
    el.setAttribute('data-id', c.id);
    el.onclick = () => toggleCard(c);
    container.appendChild(el);
  });
}

function toggleCard(c) {
  if (state.selectedCards.has(c.id)) {
    state.selectedCards.delete(c.id);
  } else {
    state.selectedCards.add(c.id);
  }
  renderMyHand();
}

function selectTribute(id) {
  const card = state.myHand.find(c => c.id === id);
  if (!card) return;
  const actType = state.gamePhase === 'tribute' ? 'tribute' : 'returnTribute';
  API.act(actType, { cards: [card] });
}

function renderSkillBar() {
  const bar = document.getElementById('skillBar');
  const skills = state.skillCards || [];
  if (skills.length === 0 || state.gamePhase !== 'playing') { bar.style.display = 'none'; return; }
  bar.style.display = 'flex';
  const myTurn = state.currentTurn === state.mySeat;
  bar.innerHTML = skills.map(s => {
    const targets = [0,1,2,3].filter(i => i !== state.mySeat && !state.winners.includes(i));
    let targetHTML = '';
    if (['Steal','Discard','Skip'].includes(s.type)) {
      targetHTML = targets.map(t => '<option value="' + t + '">' + ((state.roomPlayers[t]||{}).name||'Bot '+t) + '</option>').join('');
      targetHTML = '<select class="skill-target"><option value="">选择目标</option>' + targetHTML + '</select>';
    }
    return '<div class="skill-item" style="display:flex;flex-direction:column;align-items:center;gap:4px">' +
      '<button' + (myTurn ? '' : ' disabled') + ' onclick="useSkill(\'' + s.id + '\',\'' + s.type + '\',this)">' + skillName(s.type) + '</button>' +
      targetHTML + '</div>';
  }).join('');
}

function skillName(type) {
  const m = {DrawTwo:'无中生有',Steal:'顺手牵羊',Discard:'过河拆桥',Skip:'乐不思蜀',Harvest:'五谷丰登'};
  return m[type] || type;
}

function useSkill(id, type, btn) {
  let targetSeat = null;
  if (['Steal','Discard','Skip'].includes(type)) {
    const sel = btn.parentElement.querySelector('.skill-target');
    if (!sel || !sel.value) { showToast('请选择目标'); return; }
    targetSeat = parseInt(sel.value);
  }
  API.act('useSkill', { skillId: id, targetSeat });
}

function renderHistory(h) {} // removed

// === Chat ===
function onChatMessage(data) {
  const msgs = document.getElementById('chatMessages');
  const div = document.createElement('div');
  div.className = 'msg' + (data.sender === state.playerName ? ' mine' : '');
  if (data.sender !== state.playerName) {
    div.innerHTML = '<div class="sender">' + data.sender + '</div>' + data.text;
  } else {
    div.textContent = data.text;
  }
  msgs.appendChild(div);
  msgs.scrollTop = msgs.scrollHeight;
  // Auto-remove after 5s
  setTimeout(() => { if (div.parentNode) div.remove(); }, 5000);
}

// === Game over ===
function onGameOver(data) {
  const winners = data.winners || [];
  const pos = winners.indexOf(state.mySeat);
  showToast(pos === 0 ? '恭喜第一！' : '排名: ' + (pos + 1));
}

function onMatchOver(data) {
  const myTeam = state.mySeat % 2;
  const won = data.winningTeam === myTeam;
  showToast(won ? '恭喜获胜！' : '对方获胜！');
}

function backToLobby() {
  if (!state.inGame) { document.getElementById('lobby').classList.add('active'); document.getElementById('game').classList.remove('active'); }
  state.selectedCards.clear();
  state.myHand = [];
  state.skillCards = [];
  document.getElementById('game').classList.remove('active');
  document.getElementById('lobby').classList.add('active');
}

// === Actions ===
window._playCards = async function() {
  const btn = document.getElementById('playBtn');
  btn.textContent = '发送中...';
  if (state.selectedCards.size === 0) { btn.textContent = '没选牌!'; setTimeout(function(){btn.textContent='出牌'},1000); return; }
  const cards = state.myHand.filter(c => state.selectedCards.has(c.id));
  try {
    const result = await API.act('playHand', { cards });
    if (result && result.status === 'ok') {
      btn.textContent = 'OK!';
      state.selectedCards.clear();
      renderMyHand();
    } else {
      btn.textContent = '失败:' + ((result && result.error) || '?');
    }
  } catch(e) {
    btn.textContent = '出错:' + e.message;
  }
  setTimeout(function(){ btn.textContent = '出牌'; }, 2000);
}

window._passTurn = async function() { const b=document.getElementById('passBtn'); b.textContent='...'; try { await API.act('pass'); b.textContent='OK'; } catch(e) { b.textContent='错'; } setTimeout(function(){b.textContent='不出'},1500); }

window._hintPlay = function() {
  // Simple hint: play smallest single or lowest pair
  if (state.lastHand) {
    showToast('AI提示：查看局面后选择');
    return;
  }
  // Free play hint
  state.selectedCards.clear();
  if (state.myHand.length >= 2) {
    // Find smallest pair
    const counts = {};
    state.myHand.forEach(c => { const k = c.rank; counts[k] = (counts[k]||0)+1; });
    const pairRank = Object.entries(counts).find(([_,c]) => c >= 2);
    if (pairRank) {
      const rank = parseInt(pairRank[0]);
      state.myHand.filter(c => c.rank === rank).slice(0, 2).forEach(c => state.selectedCards.add(c.id));
    }
  }
  if (state.selectedCards.size === 0 && state.myHand.length > 0) {
    state.selectedCards.add(state.myHand[state.myHand.length-1].id);
  }
  renderMyHand();
}

function showToast(msg) {
  const el = document.getElementById('gameOverlay');
  el.style.display = 'flex';
  el.innerHTML = '<h2>' + msg + '</h2>';
  setTimeout(() => { el.style.display = 'none'; }, 2000);
}

// === Init ===
document.getElementById('joinBtn').addEventListener('click', async () => {
  const name = document.getElementById('nameInput').value.trim() || ('Player' + Math.floor(Math.random()*1000));
  const result = await API.join(name);
  if (result.status === 'ok') {
    state.playerId = result.playerId;
    state.mySeat = result.seatIndex;
    state.playerName = name;
    connectSSE();
  } else {
    alert('房间已满，请稍后再试');
  }
});


document.getElementById('startBtn').addEventListener('click', () => {
  if (!state.isHost) { alert('只有房主可以开始游戏'); return; }
  API.post('/api/start', { playerId: state.playerId });
});


document.getElementById('chatSendBtn').addEventListener('click', () => {
  const input = document.getElementById('chatInput');
  const text = input.value.trim();
  if (!text) return;
  API.act('chatMessage', { text });
  input.value = '';
});
document.getElementById('chatInput').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('chatSendBtn').click();
});

document.getElementById('gameBackBtn').addEventListener('click', backToLobby);


document.getElementById('modeNormal').addEventListener('click', () => API.act('setGameMode', { mode: 'Normal' }));
document.getElementById('modeSkill').addEventListener('click', () => API.act('setGameMode', { mode: 'Skill' }));

// Enter to join
document.getElementById('nameInput').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('joinBtn').click();
});

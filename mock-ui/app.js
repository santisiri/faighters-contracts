const TOKENS = ["WETH", "USDC", "USDT", "SAIRI"];
const WINNER_PCT = 70;
const HOUSE_PCT = 30;
const BURN_ADDRESS = "0x000000000000000000000000000000000000dEaD";

const ROLES = {
  owner: "owner",
  resolver: "resolver",
  playerA: "playerA",
  playerB: "playerB",
  playerC: "playerC",
};

const TOKEN_DECIMALS = {
  WETH: 18,
  USDC: 6,
  USDT: 6,
  SAIRI: 18,
};

const els = {
  activeCaller: byId("activeCaller"),
  nowTs: byId("nowTs"),
  warpPlus1h: byId("warpPlus1h"),
  warpPlus1d: byId("warpPlus1d"),
  resetState: byId("resetState"),

  roleSummary: byId("roleSummary"),
  globalFlags: byId("globalFlags"),

  createFightId: byId("createFightId"),
  createToken: byId("createToken"),
  createStake: byId("createStake"),
  createPlayerA: byId("createPlayerA"),
  createJoinDeadline: byId("createJoinDeadline"),
  createResolveDeadline: byId("createResolveDeadline"),
  btnCreateFight: byId("btnCreateFight"),
  btnCreateFightWithDeadlines: byId("btnCreateFightWithDeadlines"),
  btnCreateFightFor: byId("btnCreateFightFor"),
  btnCreateFightForWithDeadlines: byId("btnCreateFightForWithDeadlines"),

  joinFightId: byId("joinFightId"),
  joinPlayerB: byId("joinPlayerB"),
  btnJoinFight: byId("btnJoinFight"),
  btnJoinFightFor: byId("btnJoinFightFor"),

  resolveFightId: byId("resolveFightId"),
  resolveWinner: byId("resolveWinner"),
  resolveMinOut: byId("resolveMinOut"),
  resolveSwapOut: byId("resolveSwapOut"),
  btnResolveFight2: byId("btnResolveFight2"),
  btnResolveFight3: byId("btnResolveFight3"),

  cancelFightId: byId("cancelFightId"),
  newResolver: byId("newResolver"),
  withdrawToken: byId("withdrawToken"),
  btnPause: byId("btnPause"),
  btnUnpause: byId("btnUnpause"),
  btnCancelFight: byId("btnCancelFight"),
  btnSetResolver: byId("btnSetResolver"),
  btnEmergencyWithdraw: byId("btnEmergencyWithdraw"),

  fightTableBody: document.querySelector("#fightTable tbody"),
  balanceTableBody: document.querySelector("#balanceTable tbody"),
  reserveCards: byId("reserveCards"),
  invariantList: byId("invariantList"),
  eventFeed: byId("eventFeed"),
  eventTemplate: byId("eventTemplate"),
};

let state = bootState();

wireControls();
renderAll();
seedDemoData();

function bootState() {
  const now = Math.floor(Date.now() / 1000);
  const accounts = [
    ROLES.owner,
    ROLES.resolver,
    ROLES.playerA,
    ROLES.playerB,
    ROLES.playerC,
    "escrow",
    BURN_ADDRESS,
    "router",
  ];

  const balances = {};
  for (const account of accounts) {
    balances[account] = {};
    for (const token of TOKENS) {
      balances[account][token] = 0;
    }
  }

  for (const p of [ROLES.playerA, ROLES.playerB, ROLES.playerC]) {
    balances[p].WETH = 1000;
    balances[p].USDC = 100000;
    balances[p].USDT = 100000;
    balances[p].SAIRI = 1000;
  }

  return {
    now,
    activeCaller: ROLES.playerA,
    owner: ROLES.owner,
    resolver: ROLES.resolver,
    paused: false,
    fights: {},
    reserved: {
      WETH: 0,
      USDC: 0,
      USDT: 0,
      SAIRI: 0,
    },
    balances,
    events: [],
  };
}

function seedDemoData() {
  els.createFightId.value = "fight-demo-001";
  els.joinFightId.value = "fight-demo-001";
  els.resolveFightId.value = "fight-demo-001";
  els.cancelFightId.value = "fight-demo-001";
  emit("Helper", "Demo fields pre-filled. Try: create -> join -> resolve.");
  renderAll();
}

function wireControls() {
  const callers = [ROLES.owner, ROLES.resolver, ROLES.playerA, ROLES.playerB, ROLES.playerC];
  fillSelect(els.activeCaller, callers);
  fillSelect(els.createPlayerA, [ROLES.playerA, ROLES.playerB, ROLES.playerC]);
  fillSelect(els.joinPlayerB, [ROLES.playerB, ROLES.playerC, ROLES.playerA]);
  fillSelect(els.resolveWinner, [ROLES.playerA, ROLES.playerB, ROLES.playerC]);
  fillSelect(els.newResolver, [ROLES.playerA, ROLES.playerB, ROLES.playerC, ROLES.resolver]);
  fillSelect(els.createToken, TOKENS);
  fillSelect(els.withdrawToken, TOKENS);

  els.activeCaller.value = state.activeCaller;
  els.nowTs.value = String(state.now);

  els.activeCaller.addEventListener("change", () => {
    state.activeCaller = els.activeCaller.value;
    renderAll();
  });

  els.nowTs.addEventListener("change", () => {
    const t = toInt(els.nowTs.value);
    if (t > 0) {
      state.now = t;
      renderAll();
    }
  });

  els.warpPlus1h.addEventListener("click", () => {
    state.now += 3600;
    emit("TimeWarp", "Advanced +1 hour.");
    renderAll();
  });

  els.warpPlus1d.addEventListener("click", () => {
    state.now += 86400;
    emit("TimeWarp", "Advanced +1 day.");
    renderAll();
  });

  els.resetState.addEventListener("click", () => {
    state = bootState();
    els.activeCaller.value = state.activeCaller;
    els.nowTs.value = String(state.now);
    emit("System", "State reset to defaults.");
    renderAll();
  });

  els.btnCreateFight.addEventListener("click", () => {
    txWrap("createFight", () => {
      createFight({
        fightId: cleanFightId(els.createFightId.value),
        token: els.createToken.value,
        stakeAmount: toInt(els.createStake.value),
        playerA: state.activeCaller,
        joinDeadline: 0,
        resolveDeadline: 0,
        viaResolver: false,
      });
    });
  });

  els.btnCreateFightWithDeadlines.addEventListener("click", () => {
    txWrap("createFightWithDeadlines", () => {
      createFight({
        fightId: cleanFightId(els.createFightId.value),
        token: els.createToken.value,
        stakeAmount: toInt(els.createStake.value),
        playerA: state.activeCaller,
        joinDeadline: optionalInt(els.createJoinDeadline.value),
        resolveDeadline: optionalInt(els.createResolveDeadline.value),
        viaResolver: false,
      });
    });
  });

  els.btnCreateFightFor.addEventListener("click", () => {
    txWrap("createFightFor", () => {
      createFight({
        fightId: cleanFightId(els.createFightId.value),
        token: els.createToken.value,
        stakeAmount: toInt(els.createStake.value),
        playerA: els.createPlayerA.value,
        joinDeadline: 0,
        resolveDeadline: 0,
        viaResolver: true,
      });
    });
  });

  els.btnCreateFightForWithDeadlines.addEventListener("click", () => {
    txWrap("createFightForWithDeadlines", () => {
      createFight({
        fightId: cleanFightId(els.createFightId.value),
        token: els.createToken.value,
        stakeAmount: toInt(els.createStake.value),
        playerA: els.createPlayerA.value,
        joinDeadline: optionalInt(els.createJoinDeadline.value),
        resolveDeadline: optionalInt(els.createResolveDeadline.value),
        viaResolver: true,
      });
    });
  });

  els.btnJoinFight.addEventListener("click", () => {
    txWrap("joinFight", () => {
      joinFight({
        fightId: cleanFightId(els.joinFightId.value),
        playerB: state.activeCaller,
        viaResolver: false,
      });
    });
  });

  els.btnJoinFightFor.addEventListener("click", () => {
    txWrap("joinFightFor", () => {
      joinFight({
        fightId: cleanFightId(els.joinFightId.value),
        playerB: els.joinPlayerB.value,
        viaResolver: true,
      });
    });
  });

  els.btnResolveFight2.addEventListener("click", () => {
    txWrap("resolveFight(fightId,winner)", () => {
      resolveFight({
        fightId: cleanFightId(els.resolveFightId.value),
        winnerAddress: els.resolveWinner.value,
        minSairiOut: 0,
        simulatedSwapOut: toInt(els.resolveSwapOut.value),
      });
    });
  });

  els.btnResolveFight3.addEventListener("click", () => {
    txWrap("resolveFight(fightId,winner,minOut)", () => {
      resolveFight({
        fightId: cleanFightId(els.resolveFightId.value),
        winnerAddress: els.resolveWinner.value,
        minSairiOut: toInt(els.resolveMinOut.value),
        simulatedSwapOut: toInt(els.resolveSwapOut.value),
      });
    });
  });

  els.btnCancelFight.addEventListener("click", () => {
    txWrap("cancelFight", () => {
      cancelFight(cleanFightId(els.cancelFightId.value));
    });
  });

  els.btnPause.addEventListener("click", () => {
    txWrap("pause", pauseContract);
  });

  els.btnUnpause.addEventListener("click", () => {
    txWrap("unpause", unpauseContract);
  });

  els.btnSetResolver.addEventListener("click", () => {
    txWrap("setResolver", () => {
      setResolver(els.newResolver.value);
    });
  });

  els.btnEmergencyWithdraw.addEventListener("click", () => {
    txWrap("emergencyWithdraw", () => {
      emergencyWithdraw(els.withdrawToken.value);
    });
  });
}

function createFight({ fightId, token, stakeAmount, playerA, joinDeadline, resolveDeadline, viaResolver }) {
  whenNotPaused();
  if (viaResolver) {
    onlyResolver();
    if (!playerA) revert("ZeroAddress");
  }
  if (!fightId) revert("InvalidFightId");
  if (!TOKENS.includes(token)) revert(`UnsupportedToken(${token})`);
  if (stakeAmount <= 0) revert("InvalidStakeAmount");
  if (state.fights[fightId]) revert(`FightAlreadyExists(${fightId})`);
  validateDeadlines(joinDeadline, resolveDeadline);

  pullStake(playerA, token, stakeAmount);
  state.reserved[token] += stakeAmount;

  state.fights[fightId] = {
    fightId,
    tokenUsed: token,
    stakeAmount,
    joinDeadline,
    resolveDeadline,
    playerA,
    playerB: "",
    playerAStaked: true,
    playerBStaked: false,
    resolved: false,
    winner: "",
  };

  emit("FightCreated", { fightId, playerA, token, stakeAmount, viaResolver });
}

function joinFight({ fightId, playerB, viaResolver }) {
  whenNotPaused();
  if (viaResolver) {
    onlyResolver();
    if (!playerB) revert("ZeroAddress");
  }
  const fight = mustFight(fightId);
  if (fight.resolved) revert(`FightResolvedAlready(${fightId})`);
  if (fight.playerBStaked) revert(`AlreadyJoined(${fightId})`);
  if (playerB === fight.playerA) revert("CannotJoinOwnFight");
  if (fight.joinDeadline !== 0 && state.now > fight.joinDeadline) {
    revert(`JoinDeadlinePassed(${fightId},${fight.joinDeadline})`);
  }

  pullStake(playerB, fight.tokenUsed, fight.stakeAmount);
  state.reserved[fight.tokenUsed] += fight.stakeAmount;

  fight.playerB = playerB;
  fight.playerBStaked = true;

  emit("FightJoined", { fightId, playerB, viaResolver });
}

function resolveFight({ fightId, winnerAddress, minSairiOut, simulatedSwapOut }) {
  whenNotPaused();
  onlyResolver();

  const fight = mustFight(fightId);
  if (fight.resolved) revert(`FightResolvedAlready(${fightId})`);
  if (!fight.playerAStaked || !fight.playerBStaked) revert(`FightNotReady(${fightId})`);
  if (winnerAddress !== fight.playerA && winnerAddress !== fight.playerB) {
    revert(`InvalidWinner(${winnerAddress})`);
  }
  if (fight.resolveDeadline !== 0 && state.now > fight.resolveDeadline) {
    revert(`ResolveDeadlinePassed(${fightId},${fight.resolveDeadline})`);
  }

  const totalPot = fight.stakeAmount * 2;
  const winnerPayout = Math.floor((totalPot * WINNER_PCT) / 100);
  const houseCut = totalPot - winnerPayout;

  if (fight.tokenUsed !== "SAIRI") {
    if (minSairiOut === 0) revert("MinSairiOutRequired");
    if (simulatedSwapOut < minSairiOut) revert("Swap slippage (simulated)");
  }

  state.reserved[fight.tokenUsed] -= totalPot;
  fight.resolved = true;
  fight.winner = winnerAddress;

  transfer("escrow", winnerAddress, fight.tokenUsed, winnerPayout);

  let sairiBurned = 0;
  if (fight.tokenUsed === "SAIRI") {
    sairiBurned = houseCut;
    transfer("escrow", BURN_ADDRESS, "SAIRI", houseCut);
  } else {
    transfer("escrow", "router", fight.tokenUsed, houseCut);
    // In production this comes from pool liquidity through SwapRouter.
    // In this mock UI we mint swap output directly into escrow for clarity.
    state.balances.escrow.SAIRI += simulatedSwapOut;
    transfer("escrow", BURN_ADDRESS, "SAIRI", simulatedSwapOut);
    sairiBurned = simulatedSwapOut;
  }

  emit("FightResolved", {
    fightId,
    winner: winnerAddress,
    tokenUsed: fight.tokenUsed,
    winnerPayout,
    houseCutInput: houseCut,
    sairiBurned,
  });
}

function cancelFight(fightId) {
  whenNotPaused();
  const fight = mustFight(fightId);
  if (fight.resolved) revert(`FightResolvedAlready(${fightId})`);

  const caller = state.activeCaller;
  const resolverCancel = caller === state.resolver;
  const playerABeforeJoin = caller === fight.playerA && !fight.playerBStaked;
  if (!resolverCancel && !playerABeforeJoin) revert("Unauthorized");

  let refundAmount = 0;
  if (fight.playerAStaked) refundAmount += fight.stakeAmount;
  if (fight.playerBStaked) refundAmount += fight.stakeAmount;

  state.reserved[fight.tokenUsed] -= refundAmount;
  fight.resolved = true;
  fight.winner = "";

  if (fight.playerAStaked) {
    transfer("escrow", fight.playerA, fight.tokenUsed, fight.stakeAmount);
  }
  if (fight.playerBStaked) {
    transfer("escrow", fight.playerB, fight.tokenUsed, fight.stakeAmount);
  }

  emit("FightCancelled", { fightId, cancelledBy: caller });
}

function pauseContract() {
  onlyOwner();
  state.paused = true;
  emit("Paused", { by: state.activeCaller });
}

function unpauseContract() {
  onlyOwner();
  state.paused = false;
  emit("Unpaused", { by: state.activeCaller });
}

function setResolver(newResolver) {
  onlyOwner();
  if (!newResolver) revert("ZeroAddress");
  const previousResolver = state.resolver;
  state.resolver = newResolver;
  emit("ResolverUpdated", { previousResolver, newResolver });
}

function emergencyWithdraw(token) {
  onlyOwner();
  const balance = state.balances.escrow[token];
  const reserved = state.reserved[token];
  const amount = Math.max(balance - reserved, 0);
  if (amount < 1) revert(`NoSurplusAvailable(${token})`);
  transfer("escrow", state.owner, token, amount);
  emit("EmergencyWithdraw", { token, to: state.owner, amount });
}

function validateDeadlines(joinDeadline, resolveDeadline) {
  if (joinDeadline !== 0 && joinDeadline <= state.now) revert("InvalidDeadlineWindow");
  if (resolveDeadline !== 0 && resolveDeadline <= state.now) revert("InvalidDeadlineWindow");
  if (joinDeadline !== 0 && resolveDeadline !== 0 && resolveDeadline <= joinDeadline) {
    revert("InvalidDeadlineWindow");
  }
}

function mustFight(fightId) {
  const fight = state.fights[fightId];
  if (!fight) revert(`FightNotFound(${fightId})`);
  return fight;
}

function whenNotPaused() {
  if (state.paused) revert("EnforcedPause");
}

function onlyResolver() {
  if (state.activeCaller !== state.resolver) revert("ResolverOnly");
}

function onlyOwner() {
  if (state.activeCaller !== state.owner) revert("OwnableUnauthorizedAccount");
}

function pullStake(from, token, amount) {
  if (state.balances[from][token] < amount) {
    revert(`ERC20InsufficientBalance(${from},${token})`);
  }
  transfer(from, "escrow", token, amount);
}

function transfer(from, to, token, amount) {
  if (amount < 0) revert("NegativeAmount");
  if (state.balances[from][token] < amount) {
    revert(`TransferUnderflow(${from},${token})`);
  }
  state.balances[from][token] -= amount;
  state.balances[to][token] += amount;
}

function txWrap(label, fn) {
  try {
    fn();
    emit("CallSuccess", {
      fn: label,
      caller: state.activeCaller,
      now: state.now,
    });
  } catch (err) {
    emit("CallRevert", {
      fn: label,
      caller: state.activeCaller,
      reason: String(err.message || err),
      now: state.now,
    });
  }
  renderAll();
}

function emit(type, payload) {
  state.events.unshift({
    type,
    payload,
    ts: state.now,
  });
  state.events = state.events.slice(0, 120);
}

function renderAll() {
  els.nowTs.value = String(state.now);
  renderRoleSummary();
  renderGlobalFlags();
  renderFightTable();
  renderBalanceTable();
  renderReserveCards();
  renderInvariantWatch();
  renderEventFeed();
}

function renderRoleSummary() {
  els.roleSummary.innerHTML = "";
  for (const [label, value] of [
    ["owner", state.owner],
    ["resolver", state.resolver],
    ["active caller", state.activeCaller],
  ]) {
    const li = document.createElement("li");
    li.innerHTML = `<span>${escape(label)}</span><strong>${escape(value)}</strong>`;
    els.roleSummary.appendChild(li);
  }
}

function renderGlobalFlags() {
  els.globalFlags.innerHTML = "";
  const rows = [
    ["paused", state.paused ? "true" : "false"],
    ["winner pct", `${WINNER_PCT}%`],
    ["house pct", `${HOUSE_PCT}%`],
    ["pool fee", "3000 (0.3%)"],
  ];
  for (const [k, v] of rows) {
    const li = document.createElement("li");
    li.innerHTML = `<span>${escape(k)}</span><strong>${escape(v)}</strong>`;
    els.globalFlags.appendChild(li);
  }
}

function renderFightTable() {
  els.fightTableBody.innerHTML = "";
  const entries = Object.values(state.fights);
  if (entries.length === 0) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td colspan="11">No fights yet.</td>`;
    els.fightTableBody.appendChild(tr);
    return;
  }

  for (const fight of entries) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${escape(fight.fightId)}</td>
      <td>${escape(fight.tokenUsed)}</td>
      <td>${fmtNum(fight.stakeAmount)}</td>
      <td>${escape(orDash(fight.playerA))}</td>
      <td>${escape(orDash(fight.playerB))}</td>
      <td>${fight.playerAStaked}</td>
      <td>${fight.playerBStaked}</td>
      <td>${fight.resolved}</td>
      <td>${escape(orDash(fight.winner))}</td>
      <td>${fmtDeadline(fight.joinDeadline)}</td>
      <td>${fmtDeadline(fight.resolveDeadline)}</td>
    `;
    els.fightTableBody.appendChild(tr);
  }
}

function renderBalanceTable() {
  els.balanceTableBody.innerHTML = "";
  const accounts = [
    state.owner,
    state.resolver,
    ROLES.playerA,
    ROLES.playerB,
    ROLES.playerC,
    "escrow",
    "router",
    BURN_ADDRESS,
  ];

  for (const acct of accounts) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${escape(acct)}</td>
      <td>${fmtNum(state.balances[acct].WETH)}</td>
      <td>${fmtNum(state.balances[acct].USDC)}</td>
      <td>${fmtNum(state.balances[acct].USDT)}</td>
      <td>${fmtNum(state.balances[acct].SAIRI)}</td>
    `;
    els.balanceTableBody.appendChild(tr);
  }
}

function renderReserveCards() {
  els.reserveCards.innerHTML = "";
  for (const token of TOKENS) {
    const balance = state.balances.escrow[token];
    const reserved = state.reserved[token];
    const surplus = Math.max(balance - reserved, 0);
    const card = document.createElement("article");
    card.className = "stat-card";
    card.innerHTML = `
      <h4>${token} reserve model</h4>
      <p>escrow balance: ${fmtNum(balance)}</p>
      <p>reserved liability: ${fmtNum(reserved)}</p>
      <p>withdrawable surplus: ${fmtNum(surplus)}</p>
      <p>decimals: ${TOKEN_DECIMALS[token]}</p>
    `;
    els.reserveCards.appendChild(card);
  }
}

function renderInvariantWatch() {
  const checks = computeInvariantChecks();
  els.invariantList.innerHTML = "";
  for (const check of checks) {
    const li = document.createElement("li");
    const klass = check.ok ? "check-ok" : "check-bad";
    li.className = klass;
    li.textContent = `${check.ok ? "PASS" : "FAIL"}: ${check.message}`;
    els.invariantList.appendChild(li);
  }
}

function computeInvariantChecks() {
  const checks = [];

  for (const token of TOKENS) {
    const balance = state.balances.escrow[token];
    const reserved = state.reserved[token];
    checks.push({
      ok: balance >= reserved,
      message: `${token} escrow balance >= reserved (${balance} >= ${reserved})`,
    });
  }

  const liabilities = { WETH: 0, USDC: 0, USDT: 0, SAIRI: 0 };
  for (const fight of Object.values(state.fights)) {
    if (!fight.resolved) {
      if (fight.playerAStaked) liabilities[fight.tokenUsed] += fight.stakeAmount;
      if (fight.playerBStaked) liabilities[fight.tokenUsed] += fight.stakeAmount;
    }

    const winnerConsistent =
      !fight.resolved ||
      !fight.winner ||
      fight.winner === fight.playerA ||
      fight.winner === fight.playerB;

    checks.push({
      ok: winnerConsistent,
      message: `winner consistency for ${fight.fightId}`,
    });
  }

  for (const token of TOKENS) {
    checks.push({
      ok: liabilities[token] === state.reserved[token],
      message: `${token} liability == reserved (${liabilities[token]} == ${state.reserved[token]})`,
    });
  }

  return checks;
}

function renderEventFeed() {
  els.eventFeed.innerHTML = "";

  if (state.events.length === 0) {
    els.eventFeed.textContent = "No events yet.";
    return;
  }

  for (const event of state.events) {
    const node = els.eventTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector(".event-meta").textContent = `[${event.ts}] ${event.type}`;
    node.querySelector(".event-body").textContent = JSON.stringify(event.payload, null, 2);
    els.eventFeed.appendChild(node);
  }
}

function fillSelect(select, values) {
  select.innerHTML = "";
  for (const value of values) {
    const opt = document.createElement("option");
    opt.value = value;
    opt.textContent = value;
    select.appendChild(opt);
  }
}

function byId(id) {
  const el = document.getElementById(id);
  if (!el) {
    throw new Error(`Missing element #${id}`);
  }
  return el;
}

function toInt(v) {
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.floor(n));
}

function optionalInt(v) {
  if (v === "" || v == null) return 0;
  return toInt(v);
}

function cleanFightId(v) {
  return String(v || "").trim();
}

function fmtNum(n) {
  return Number(n).toLocaleString();
}

function fmtDeadline(ts) {
  if (!ts) return "-";
  return `${ts} (${ts > state.now ? "future" : "passed"})`;
}

function orDash(v) {
  return v && v.length ? v : "-";
}

function escape(v) {
  return String(v)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function revert(message) {
  throw new Error(message);
}

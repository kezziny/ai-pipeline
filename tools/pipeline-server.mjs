#!/usr/bin/env node
/**
 * tools/pipeline-server.mjs
 *
 * Zero-dependency Node.js Local REST API Proxy & State Coordinator for the
 * Autonomous Multi-Agent Development Pipeline.
 *
 * Solves GitHub GraphQL & Secondary Rate Limits via 5 mechanisms:
 * 1. Read-Through Memory Mirror + Conditional REST ETag (304 Not Modified = 0 quota).
 * 2. Slim 1-Point GraphQL Project Sync (fetches only Status & Attention fields).
 * 3. Instant Write-Through Pub/Sub (<5ms handoff between roles via EventEmitter).
 * 4. Serialized FIFO Write Queue + Aliased GraphQL Mutation Batching (1.2s pacing).
 * 5. Passive Rate-Limit Header Tracking & Optional Multi-Token Pool Rotation.
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, '..');
const CONFIG_FILE = path.join(ROOT_DIR, '.project-config.json');

// -----------------------------------------------------------------------------
// 1. Configuration & Token Pool Initialization
// -----------------------------------------------------------------------------

function loadConfig() {
  let cfg = {};
  if (fs.existsSync(CONFIG_FILE)) {
    try {
      cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    } catch {
      // Ignore malformed config
    }
  }

  let detectedRepo = process.env.GH_REPO || cfg.repo || '';
  if (!detectedRepo) {
    try {
      const remoteUrl = execFileSync('git', ['remote', 'get-url', 'origin'], {
        cwd: ROOT_DIR,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
      const match = remoteUrl.match(/github\.com[:/]([^/]+\/[^/.]+)(?:\.git)?$/);
      if (match) detectedRepo = match[1];
    } catch {
      // Ignore if not a git repo
    }
  }

  return {
    owner: process.env.GH_PROJECT_OWNER || cfg.owner || '',
    projectNumber: Number(process.env.GH_PROJECT_NUMBER || cfg.projectNumber || 0),
    repo: detectedRepo,
    statusFieldName: (process.env.GH_PROJECT_STATUS_FIELD || cfg.statusFieldName || 'Status').trim(),
    attentionFieldName: (process.env.GH_PROJECT_ATTENTION_FIELD || cfg.attentionFieldName || 'Attention').trim(),
    port: Number(process.env.GH_PIPELINE_PORT || cfg.proxyPort || 4100),
    host: process.env.GH_PIPELINE_HOST || '127.0.0.1',
    syncIntervalMs: Number(process.env.GH_PIPELINE_SYNC_MS || 25000),
    mutationPaceMs: Number(process.env.GH_PIPELINE_MUTATION_PACE_MS || 1200),
    maxBounces: Number(process.env.GH_PROJECT_MAX_BOUNCES || 3),
    mockMode: process.env.GH_PIPELINE_MOCK === '1',
  };
}

const config = loadConfig();

function resolveTokens() {
  if (config.mockMode) return ['mock-token'];
  const envPool = process.env.GH_TOKENS || process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '';
  const list = envPool
    .split(',')
    .map((t) => t.trim())
    .filter(Boolean);
  if (list.length > 0) return list;

  for (const cmd of ['gh-bot', path.join(process.env.HOME || '', '.config/gh/gh-bot'), 'gh']) {
    try {
      const tok = execFileSync(cmd, ['auth', 'token'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
      if (tok) return [tok];
    } catch {
      // Try next command
    }
  }
  return [];
}

const tokenPool = resolveTokens().map((token, idx) => ({
  id: `token-${idx + 1}`,
  token,
  restRemaining: 5000,
  restReset: 0,
  graphqlRemaining: 5000,
  graphqlReset: 0,
}));

function pickToken(kind = 'rest') {
  if (tokenPool.length === 0) {
    throw new Error('No GitHub token available. Authenticate via `gh auth login` or set GH_TOKEN / GH_TOKENS.');
  }
  const key = kind === 'graphql' ? 'graphqlRemaining' : 'restRemaining';
  return [...tokenPool].sort((a, b) => b[key] - a[key])[0];
}

function updateRateLimitFromHeaders(tokObj, headers, kind = 'rest') {
  if (!tokObj || !headers) return;
  const rem = headers.get('x-ratelimit-remaining');
  const reset = headers.get('x-ratelimit-reset');
  const resource = (headers.get('x-ratelimit-resource') || kind).toLowerCase();
  if (rem !== null) {
    const val = Number(rem);
    if (resource.includes('graphql')) tokObj.graphqlRemaining = val;
    else tokObj.restRemaining = val;
  }
  if (reset !== null) {
    const val = Number(reset);
    if (resource.includes('graphql')) tokObj.graphqlReset = val;
    else tokObj.restReset = val;
  }
}

// -----------------------------------------------------------------------------
// 2. Alias Normalization & Stage Ordering
// -----------------------------------------------------------------------------

const STATUS_ALIASES = {
  'role-product-manager': 'pm',
  'product-manager': 'pm',
  'product manager': 'pm',
  pm: 'pm',
  'role-senior-developer': 'senior dev',
  'senior-developer': 'senior dev',
  'senior developer': 'senior dev',
  'senior-dev': 'senior dev',
  'senior dev': 'senior dev',
  'role-architect': 'architect',
  architect: 'architect',
  'role-implementer': 'implementer',
  'issue-implementer': 'implementer',
  implementer: 'implementer',
  'role-code-reviewer': 'code review',
  'code-reviewer': 'code review',
  'code reviewer': 'code review',
  'code-review': 'code review',
  'code review': 'code review',
  'role-qa-engineer': 'qa',
  'qa-engineer': 'qa',
  'qa engineer': 'qa',
  qa: 'qa',
  ready: 'ready',
  done: 'done',
  backlog: 'backlog',
};

const ATTENTION_ALIASES = {
  standard: 'standard',
  'needs decision': 'needs decision',
  'needs-decision': 'needs decision',
  needs_decision: 'needs decision',
  decision: 'needs decision',
};

const STAGE_ORDER = {
  backlog: 0,
  pm: 1,
  'senior dev': 2,
  architect: 3,
  ready: 4,
  implementer: 5,
  'code review': 6,
  qa: 7,
  done: 8,
};

function normStatus(s) {
  const clean = String(s || '').trim().toLowerCase();
  return STATUS_ALIASES[clean] || clean;
}

function normAttention(a) {
  const clean = String(a || '').trim().toLowerCase();
  if (!clean) return 'standard';
  return ATTENTION_ALIASES[clean] || clean;
}

// -----------------------------------------------------------------------------
// 3. In-Memory State, ETag Cache, Singleflight & Write Queue
// -----------------------------------------------------------------------------

const bus = new EventEmitter();
bus.setMaxListeners(100);

const state = {
  projectMeta: null, // { projectId, statusFieldId, statusOptions: Map, attentionFieldId, attentionOptions: Map, fetchedAt }
  boardItems: new Map(), // issueNumber (string) -> { itemId, number, title, url, repo, status, attention, updatedAt }
  lastBoardSyncAt: 0,
  issuesCache: new Map(), // issueNumber (string) -> { data, fetchedAt }
  bounces: new Map(), // issueNumber (string) -> number
  etagCache: new Map(), // url -> { etag, data, fetchedAt }
  inFlight: new Map(), // key -> Promise
  writeQueue: [],
  writeWorkerActive: false,
  stats: {
    restCalls: 0,
    rest304Hits: 0,
    memoryCacheHits: 0,
    graphqlCalls: 0,
    batchedMutations: 0,
    startedAt: new Date().toISOString(),
  },
};

// Load existing bounce files from /tmp for compatibility with project-move.sh
function getBounceCount(issueNum) {
  const key = String(issueNum);
  if (state.bounces.has(key)) return state.bounces.get(key);
  const bounceFile = `/tmp/gh-bounce-${config.owner}-${config.projectNumber}-${key}.count`;
  if (fs.existsSync(bounceFile)) {
    try {
      const count = Number(fs.readFileSync(bounceFile, 'utf8').trim() || '0');
      state.bounces.set(key, count);
      return count;
    } catch {
      return 0;
    }
  }
  return 0;
}

function setBounceCount(issueNum, count) {
  const key = String(issueNum);
  const bounceFile = `/tmp/gh-bounce-${config.owner}-${config.projectNumber}-${key}.count`;
  if (count <= 0) {
    state.bounces.delete(key);
    try {
      if (fs.existsSync(bounceFile)) fs.unlinkSync(bounceFile);
    } catch {
      // Ignore
    }
  } else {
    state.bounces.set(key, count);
    try {
      fs.writeFileSync(bounceFile, String(count), 'utf8');
    } catch {
      // Ignore
    }
  }
}

// -----------------------------------------------------------------------------
// 4. Upstream GitHub REST (ETag-Cached) & GraphQL Client
// -----------------------------------------------------------------------------

async function githubRest(apiPath, { method = 'GET', body = null, ttlMs = 15000 } = {}) {
  if (config.mockMode) {
    return mockGithubRest(apiPath, { method, body });
  }

  const url = apiPath.startsWith('http') ? apiPath : `https://api.github.com${apiPath}`;
  const isRead = method === 'GET';

  if (isRead) {
    const cached = state.etagCache.get(url);
    if (cached && Date.now() - cached.fetchedAt < ttlMs) {
      state.stats.memoryCacheHits += 1;
      return cached.data;
    }
    if (state.inFlight.has(url)) {
      state.stats.memoryCacheHits += 1;
      return state.inFlight.get(url);
    }
  }

  const runRequest = async () => {
    const tokObj = pickToken('rest');
    const headers = {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${tokObj.token}`,
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'ai-pipeline-local-proxy/1.0',
    };

    const cached = isRead ? state.etagCache.get(url) : null;
    if (isRead && cached?.etag) {
      headers['If-None-Match'] = cached.etag;
    }
    if (body !== null) {
      headers['Content-Type'] = 'application/json';
    }

    state.stats.restCalls += 1;
    const res = await fetch(url, {
      method,
      headers,
      body: body !== null ? JSON.stringify(body) : undefined,
    });

    updateRateLimitFromHeaders(tokObj, res.headers, 'rest');

    if (res.status === 304 && cached) {
      state.stats.rest304Hits += 1;
      cached.fetchedAt = Date.now();
      return cached.data;
    }

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`GitHub REST ${method} ${apiPath} failed (${res.status}): ${errText.slice(0, 300)}`);
    }

    const data = res.status === 204 ? null : await res.json();
    if (isRead) {
      const etag = res.headers.get('etag');
      state.etagCache.set(url, { etag, data, fetchedAt: Date.now() });
    }
    return data;
  };

  if (isRead) {
    const p = runRequest().finally(() => state.inFlight.delete(url));
    state.inFlight.set(url, p);
    return p;
  }
  return runRequest();
}

async function githubGraphql(query, variables = {}) {
  if (config.mockMode) {
    return mockGithubGraphql(query, variables);
  }

  const tokObj = pickToken('graphql');
  state.stats.graphqlCalls += 1;
  const res = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${tokObj.token}`,
      'Content-Type': 'application/json',
      'User-Agent': 'ai-pipeline-local-proxy/1.0',
    },
    body: JSON.stringify({ query, variables }),
  });

  updateRateLimitFromHeaders(tokObj, res.headers, 'graphql');

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`GitHub GraphQL failed (${res.status}): ${errText.slice(0, 300)}`);
  }

  const payload = await res.json();
  if (payload.errors && payload.errors.length > 0 && !payload.data) {
    throw new Error(`GitHub GraphQL error: ${JSON.stringify(payload.errors[0].message)}`);
  }
  return payload.data;
}

// -----------------------------------------------------------------------------
// 5. Slim 1-Point GraphQL Project Metadata & Board Sync
// -----------------------------------------------------------------------------

async function ensureProjectMeta() {
  if (state.projectMeta && Date.now() - state.projectMeta.fetchedAt < 86400000) {
    return state.projectMeta;
  }

  const query = `
    query($owner: String!, $number: Int!) {
      user(login: $owner) {
        projectV2(number: $number) {
          id
          fields(first: 30) {
            nodes {
              ... on ProjectV2SingleSelectField {
                id
                name
                options { id name }
              }
            }
          }
        }
      }
      organization(login: $owner) {
        projectV2(number: $number) {
          id
          fields(first: 30) {
            nodes {
              ... on ProjectV2SingleSelectField {
                id
                name
                options { id name }
              }
            }
          }
        }
      }
    }
  `;

  const data = await githubGraphql(query, {
    owner: config.owner,
    number: config.projectNumber,
  });

  const proj = data?.user?.projectV2 || data?.organization?.projectV2;
  if (!proj) {
    throw new Error(`Project #${config.projectNumber} not found for owner '${config.owner}'`);
  }

  let statusFieldId = null;
  const statusOptions = new Map();
  let attentionFieldId = null;
  const attentionOptions = new Map();

  for (const f of proj.fields?.nodes || []) {
    if (!f || !f.name) continue;
    const lname = f.name.trim().toLowerCase();
    if (lname === config.statusFieldName.toLowerCase() || lname === 'status') {
      statusFieldId = f.id;
      for (const opt of f.options || []) {
        statusOptions.set(normStatus(opt.name), { id: opt.id, name: opt.name });
      }
    } else if (lname === config.attentionFieldName.toLowerCase() || lname === 'attention') {
      attentionFieldId = f.id;
      for (const opt of f.options || []) {
        attentionOptions.set(normAttention(opt.name), { id: opt.id, name: opt.name });
      }
    }
  }

  state.projectMeta = {
    projectId: proj.id,
    statusFieldId,
    statusOptions,
    attentionFieldId,
    attentionOptions,
    fetchedAt: Date.now(),
  };
  return state.projectMeta;
}

async function syncProjectBoard(force = false) {
  const tok = tokenPool[0];
  const dynamicInterval =
    tok && tok.graphqlRemaining < 400 ? Math.max(config.syncIntervalMs * 3, 75000) : config.syncIntervalMs;

  if (!force && state.lastBoardSyncAt > 0 && Date.now() - state.lastBoardSyncAt < dynamicInterval) {
    return state.boardItems;
  }

  if (state.inFlight.has('board-sync')) {
    return state.inFlight.get('board-sync');
  }

  const doSync = async () => {
    const query = `
      query($owner: String!, $number: Int!, $statusField: String!, $attentionField: String!) {
        user(login: $owner) {
          projectV2(number: $number) {
            items(first: 100) {
              nodes {
                id
                status: fieldValueByName(name: $statusField) {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                attention: fieldValueByName(name: $attentionField) {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                content {
                  ... on Issue {
                    number
                    title
                    url
                    state
                    repository { nameWithOwner }
                  }
                }
              }
            }
          }
        }
        organization(login: $owner) {
          projectV2(number: $number) {
            items(first: 100) {
              nodes {
                id
                status: fieldValueByName(name: $statusField) {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                attention: fieldValueByName(name: $attentionField) {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                content {
                  ... on Issue {
                    number
                    title
                    url
                    state
                    repository { nameWithOwner }
                  }
                }
              }
            }
          }
        }
      }
    `;

    const data = await githubGraphql(query, {
      owner: config.owner,
      number: config.projectNumber,
      statusField: config.statusFieldName,
      attentionField: config.attentionFieldName,
    });

    const nodes =
      data?.user?.projectV2?.items?.nodes || data?.organization?.projectV2?.items?.nodes || [];

    const nextMap = new Map();
    for (const node of nodes) {
      const content = node?.content;
      if (!content || content.number == null) continue;
      if (content.state && String(content.state).toUpperCase() === 'CLOSED') continue;

      const numStr = String(content.number);
      const statusRaw = node.status?.name || '';
      const attentionRaw = node.attention?.name || 'Standard';

      nextMap.set(numStr, {
        itemId: node.id,
        number: content.number,
        title: content.title || '',
        url: content.url || '',
        repo: content.repository?.nameWithOwner || config.repo,
        status: statusRaw,
        statusNorm: normStatus(statusRaw),
        attention: attentionRaw,
        attentionNorm: normAttention(attentionRaw),
        updatedAt: Date.now(),
      });
    }

    state.boardItems = nextMap;
    state.lastBoardSyncAt = Date.now();

    // Also write shared /tmp cache file so legacy tools see updated state
    try {
      const compatItems = Array.from(nextMap.values()).map((it) => ({
        id: it.itemId,
        status: it.status,
        attention: it.attention,
        content: { number: it.number, title: it.title, url: it.url },
      }));
      const cacheFile = `/tmp/gh-project-cache-${config.owner}-${config.projectNumber}.json`;
      fs.writeFileSync(cacheFile, JSON.stringify({ items: compatItems }), 'utf8');
    } catch {
      // Ignore /tmp write error
    }

    bus.emit('board-updated');
    return state.boardItems;
  };

  const p = doSync().finally(() => state.inFlight.delete('board-sync'));
  state.inFlight.set('board-sync', p);
  return p;
}

// -----------------------------------------------------------------------------
// 6. Serialized Write Queue & Batched GraphQL Mutations
// -----------------------------------------------------------------------------

function enqueueWrite(taskFn) {
  return new Promise((resolve, reject) => {
    state.writeQueue.push({ taskFn, resolve, reject });
    processWriteQueue();
  });
}

async function processWriteQueue() {
  if (state.writeWorkerActive) return;
  state.writeWorkerActive = true;

  while (state.writeQueue.length > 0) {
    const { taskFn, resolve, reject } = state.writeQueue.shift();
    try {
      const result = await taskFn();
      resolve(result);
    } catch (err) {
      reject(err);
    }
    if (state.writeQueue.length > 0 && !config.mockMode) {
      await new Promise((r) => setTimeout(r, config.mutationPaceMs));
    }
  }

  state.writeWorkerActive = false;
}

// -----------------------------------------------------------------------------
// 7. Rich Context & Check-Runs Hydration (100% REST + ETag = 0 GraphQL Points)
// -----------------------------------------------------------------------------

async function fetchPrChecksRest(repo, headSha) {
  if (!repo || !headSha) {
    return { state: 'unknown', total: 0, passed: 0, failed: 0, pending: 0, details: [] };
  }
  const data = await githubRest(`/repos/${repo}/commits/${headSha}/check-runs?per_page=100`, {
    ttlMs: 12000,
  });
  const runs = data?.check_runs || [];
  let passed = 0;
  let failed = 0;
  let pending = 0;
  const details = [];

  for (const r of runs) {
    const st = String(r.status || '').toLowerCase();
    const concl = String(r.conclusion || '').toLowerCase();
    if (st !== 'completed') {
      pending += 1;
    } else if (['success', 'neutral', 'skipped'].includes(concl)) {
      passed += 1;
    } else {
      failed += 1;
    }
    details.push({
      name: r.name,
      status: r.status,
      conclusion: r.conclusion,
      url: r.html_url || r.details_url || '',
    });
  }

  let overall = 'success';
  if (failed > 0) overall = 'failure';
  else if (pending > 0) overall = 'pending';

  return {
    state: overall,
    total: runs.length,
    passed,
    failed,
    pending,
    details,
  };
}

async function findLinkedPrRest(repo, issueNum) {
  if (!repo) return null;
  const pulls = await githubRest(`/repos/${repo}/pulls?state=open&per_page=50`, { ttlMs: 15000 });
  const numStr = String(issueNum);
  const branchRe = new RegExp(`^(?:feat|feature|fix|refactor|chore)/(?:issue-)?${numStr}\\b`, 'i');
  const bodyRe = new RegExp(`#${numStr}\\b`);

  const matched = (pulls || []).find(
    (pr) =>
      branchRe.test(pr.head?.ref || '') ||
      bodyRe.test(pr.title || '') ||
      bodyRe.test(pr.body || '')
  );
  if (!matched) return null;

  // Fetch single PR resource (ETag cached) to get accurate `mergeable` & `mergeable_state`
  const fullPr = await githubRest(`/repos/${repo}/pulls/${matched.number}`, { ttlMs: 15000 });
  const checks = await fetchPrChecksRest(repo, fullPr.head?.sha);

  return {
    number: fullPr.number,
    title: fullPr.title,
    url: fullPr.html_url,
    headRefName: fullPr.head?.ref || '',
    headSha: fullPr.head?.sha || '',
    isDraft: Boolean(fullPr.draft),
    mergeable: fullPr.mergeable,
    mergeableState: fullPr.mergeable_state || '',
    checks,
  };
}

async function getHydratedIssueContext(issueNum) {
  const numStr = String(issueNum);
  const boardItem = state.boardItems.get(numStr);
  const repo = boardItem?.repo || config.repo;
  if (!repo) {
    throw new Error('Repository nameWithOwner (e.g. owner/repo) not configured or detected.');
  }

  const [issueData, commentsData, linkedPr] = await Promise.all([
    githubRest(`/repos/${repo}/issues/${numStr}`, { ttlMs: 15000 }),
    githubRest(`/repos/${repo}/issues/${numStr}/comments?per_page=30`, { ttlMs: 15000 }),
    findLinkedPrRest(repo, numStr),
  ]);

  return {
    number: issueData.number,
    title: issueData.title,
    body: issueData.body || '',
    state: issueData.state,
    url: issueData.html_url,
    status: boardItem?.status || '',
    attention: boardItem?.attention || 'Standard',
    itemId: boardItem?.itemId || '',
    bounceCount: getBounceCount(numStr),
    comments: (commentsData || []).slice(-15).map((c) => ({
      id: c.id,
      author: c.user?.login || '',
      body: c.body || '',
      createdAt: c.created_at,
    })),
    pr: linkedPr,
  };
}

// -----------------------------------------------------------------------------
// 8. Board Transition + Circuit Breaker + Batched GraphQL Mutation
// -----------------------------------------------------------------------------

async function transitionIssue(issueNum, payload = {}) {
  const numStr = String(issueNum).replace(/^#/, '');
  await syncProjectBoard(false);

  let item = state.boardItems.get(numStr);
  if (!item) {
    await syncProjectBoard(true);
    item = state.boardItems.get(numStr);
  }
  if (!item) {
    throw new Error(`Issue #${numStr} not found on Project #${config.projectNumber}`);
  }

  const repo = item.repo || config.repo;
  if (payload.reset_bounces) {
    setBounceCount(numStr, 0);
    if (!payload.status && !payload.attention && !payload.comment && !payload.pr_comment) {
      return { ok: true, number: Number(numStr), resetBounces: true };
    }
  }

  let targetStatus = payload.status ? String(payload.status).trim() : '';
  let targetAttention = payload.attention ? String(payload.attention).trim() : '';
  const maxBounces = payload.max_bounces !== undefined ? Number(payload.max_bounces) : config.maxBounces;

  const targetStatusNorm = targetStatus ? normStatus(targetStatus) : '';
  let targetAttNorm = targetAttention ? normAttention(targetAttention) : '';

  // Evaluate 3-Bounce Circuit Breaker in memory
  let circuitBreakerTriggered = false;
  let bounceCount = getBounceCount(numStr);

  if (targetStatusNorm === 'ready' || targetStatusNorm === 'done') {
    setBounceCount(numStr, 0);
    bounceCount = 0;
  } else if (targetStatusNorm && item.statusNorm) {
    const curIdx = STAGE_ORDER[item.statusNorm] ?? -1;
    const tgtIdx = STAGE_ORDER[targetStatusNorm] ?? -1;
    if (curIdx > tgtIdx && tgtIdx >= 0) {
      bounceCount += 1;
      if (maxBounces > 0 && bounceCount >= maxBounces) {
        circuitBreakerTriggered = true;
        targetAttention = 'Needs Decision';
        targetAttNorm = 'needs decision';
        setBounceCount(numStr, 0);
      } else {
        setBounceCount(numStr, bounceCount);
      }
    }
  }

  // Write-Through Memory Update: Update local board state immediately so waiting /poll wakes in <5ms!
  if (targetStatus) {
    item.status = targetStatus;
    item.statusNorm = targetStatusNorm;
  }
  if (targetAttention) {
    item.attention = targetAttention;
    item.attentionNorm = targetAttNorm;
  }
  item.updatedAt = Date.now();
  state.boardItems.set(numStr, item);
  bus.emit('board-updated');

  // Enqueue upstream mutations in serialized FIFO queue
  await enqueueWrite(async () => {
    const meta = await ensureProjectMeta();
    const mutations = [];
    const varDefs = ['$projectId: ID!', '$itemId: ID!'];
    const vars = { projectId: meta.projectId, itemId: item.itemId };

    if (targetStatusNorm && meta.statusFieldId) {
      const opt = meta.statusOptions.get(targetStatusNorm);
      if (opt) {
        varDefs.push('$statusFieldId: ID!', '$statusOptId: String!');
        vars.statusFieldId = meta.statusFieldId;
        vars.statusOptId = opt.id;
        item.status = opt.name;
        mutations.push(`
          updateStatus: updateProjectV2ItemFieldValue(input: {
            projectId: $projectId,
            itemId: $itemId,
            fieldId: $statusFieldId,
            value: { singleSelectOptionId: $statusOptId }
          }) { projectV2Item { id } }
        `);
      }
    }

    if (targetAttNorm && meta.attentionFieldId) {
      const opt = meta.attentionOptions.get(targetAttNorm);
      if (opt) {
        varDefs.push('$attFieldId: ID!', '$attOptId: String!');
        vars.attFieldId = meta.attentionFieldId;
        vars.attOptId = opt.id;
        item.attention = opt.name;
        mutations.push(`
          updateAttention: updateProjectV2ItemFieldValue(input: {
            projectId: $projectId,
            itemId: $itemId,
            fieldId: $attFieldId,
            value: { singleSelectOptionId: $attOptId }
          }) { projectV2Item { id } }
        `);
      }
    }

    if (mutations.length > 0) {
      const batchedQuery = `mutation(${varDefs.join(', ')}) { ${mutations.join('\n')} }`;
      await githubGraphql(batchedQuery, vars);
      state.stats.batchedMutations += 1;
    }

    if (payload.comment && repo) {
      await githubRest(`/repos/${repo}/issues/${numStr}/comments`, {
        method: 'POST',
        body: { body: payload.comment },
      });
    }

    if (payload.pr_comment && payload.pr_number && repo) {
      await githubRest(`/repos/${repo}/issues/${payload.pr_number}/comments`, {
        method: 'POST',
        body: { body: payload.pr_comment },
      });
    }

    if (circuitBreakerTriggered && repo) {
      const cbMsg =
        `⚠️ **Pipeline Circuit Breaker Triggered**: Issue #${numStr} has been routed backward ` +
        `${bounceCount} times (threshold: ${maxBounces}). Automatically escalating 'Attention' to ` +
        `**Needs Decision** to prevent an infinite agent ping-pong loop.`;
      await githubRest(`/repos/${repo}/issues/${numStr}/comments`, {
        method: 'POST',
        body: { body: cbMsg },
      });
    }
  });

  return {
    ok: true,
    number: Number(numStr),
    itemId: item.itemId,
    status: item.status,
    attention: item.attention,
    circuitBreakerTriggered,
    bounceCount,
  };
}

// -----------------------------------------------------------------------------
// 9. Smart Long-Polling Handler (with Zero-Token Conflict & CI Auto-Bounce)
// -----------------------------------------------------------------------------

async function findMatchingBoardItem(targetStatus, targetAttention, autoBounceCi) {
  await syncProjectBoard(false);
  const wantStatus = normStatus(targetStatus);
  const wantAtt = normAttention(targetAttention);

  for (const item of state.boardItems.values()) {
    if (item.statusNorm !== wantStatus || item.attentionNorm !== wantAtt) continue;

    if (autoBounceCi && ( item.repo || config.repo )) {
      const repo = item.repo || config.repo;
      try {
        const pr = await findLinkedPrRest(repo, item.number);
        if (pr) {
          if (pr.mergeable === false || String(pr.mergeableState).toLowerCase() === 'dirty') {
            await transitionIssue(item.number, {
              status: 'Implementer',
              attention: 'Standard',
              pr_number: pr.number,
              pr_comment:
                '❌ Merge conflict with base branch detected (`mergeable: CONFLICTING`). Bouncing issue back to Implementer to rebase onto latest `origin/master`.',
            });
            continue;
          }
          if (pr.checks.state === 'failure') {
            const failedNames = pr.checks.details
              .filter((d) => d.status === 'completed' && !['success', 'neutral', 'skipped'].includes(String(d.conclusion).toLowerCase()))
              .map((d) => `- ${d.name}: ${d.conclusion}`)
              .slice(0, 10)
              .join('\n');
            await transitionIssue(item.number, {
              status: 'Implementer',
              attention: 'Standard',
              pr_number: pr.number,
              pr_comment: `❌ Automated PR checks failed on CI. Bouncing issue back to Implementer:\n\`\`\`\n${failedNames}\n\`\`\``,
            });
            continue;
          }
          if (pr.checks.state === 'pending') {
            // Do not wake agent while CI is still running
            continue;
          }
        }
      } catch {
        // If PR lookup fails transiently, allow match
      }
    }

    return item;
  }
  return null;
}

// -----------------------------------------------------------------------------
// 10. Mock Mode Support (For Deterministic Offline Unit Tests)
// -----------------------------------------------------------------------------

const mockDb = {
  items: new Map([
    [
      '42',
      {
        itemId: 'PVTI_mock_42',
        number: 42,
        title: 'Implement Local REST Proxy',
        url: 'https://github.com/kezziny/ai-pipeline/issues/42',
        repo: 'kezziny/ai-pipeline',
        status: 'PM',
        attention: 'Standard',
        body: 'Initial mock issue body',
        comments: [],
        pr: {
          number: 101,
          title: 'feat(#42): local rest proxy',
          headRefName: 'feature/42-local-rest-proxy',
          headSha: 'abc1234',
          draft: false,
          mergeable: true,
          mergeable_state: 'clean',
          checkRuns: [{ name: 'test', status: 'completed', conclusion: 'success' }],
        },
      },
    ],
  ]),
};

function mockGithubGraphql(query) {
  if (query.includes('fields(first: 30)')) {
    return {
      user: {
        projectV2: {
          id: 'PVT_mock_1',
          fields: {
            nodes: [
              {
                id: 'PVTF_status',
                name: 'Status',
                options: [
                  { id: 'opt_backlog', name: 'Backlog' },
                  { id: 'opt_pm', name: 'PM' },
                  { id: 'opt_sdev', name: 'Senior Dev' },
                  { id: 'opt_arch', name: 'Architect' },
                  { id: 'opt_ready', name: 'Ready' },
                  { id: 'opt_impl', name: 'Implementer' },
                  { id: 'opt_rev', name: 'Code Review' },
                  { id: 'opt_qa', name: 'QA' },
                  { id: 'opt_done', name: 'Done' },
                ],
              },
              {
                id: 'PVTF_att',
                name: 'Attention',
                options: [
                  { id: 'opt_std', name: 'Standard' },
                  { id: 'opt_nd', name: 'Needs Decision' },
                ],
              },
            ],
          },
        },
      },
    };
  }
  if (query.includes('items(first: 100)')) {
    return {
      user: {
        projectV2: {
          items: {
            nodes: Array.from(mockDb.items.values()).map((it) => ({
              id: it.itemId,
              status: { name: it.status },
              attention: { name: it.attention },
              content: {
                number: it.number,
                title: it.title,
                url: it.url,
                state: 'OPEN',
                repository: { nameWithOwner: it.repo },
              },
            })),
          },
        },
      },
    };
  }
  return { updateStatus: { projectV2Item: { id: 'PVTI_mock_42' } } };
}

function mockGithubRest(apiPath, { method, body }) {
  const it = mockDb.items.get('42');
  if (apiPath.endsWith('/issues/42') && method === 'GET') {
    return { number: 42, title: it.title, body: it.body, state: 'open', html_url: it.url };
  }
  if (apiPath.endsWith('/issues/42') && method === 'PATCH') {
    if (body?.title) it.title = body.title;
    if (body?.body) it.body = body.body;
    return { number: 42, title: it.title, body: it.body, state: 'open', html_url: it.url };
  }
  if (apiPath.includes('/issues/42/comments') && method === 'GET') {
    return it.comments;
  }
  if (apiPath.includes('/comments') && method === 'POST') {
    const c = { id: it.comments.length + 1, user: { login: 'bot' }, body: body?.body || '', created_at: new Date().toISOString() };
    it.comments.push(c);
    return c;
  }
  if (apiPath.includes('/pulls?state=open')) {
    return [
      {
        number: it.pr.number,
        title: it.pr.title,
        html_url: 'https://github.com/kezziny/ai-pipeline/pull/101',
        head: { ref: it.pr.headRefName, sha: it.pr.headSha },
        draft: it.pr.draft,
      },
    ];
  }
  if (apiPath.endsWith(`/pulls/${it.pr.number}`)) {
    return {
      number: it.pr.number,
      title: it.pr.title,
      html_url: 'https://github.com/kezziny/ai-pipeline/pull/101',
      head: { ref: it.pr.headRefName, sha: it.pr.headSha },
      draft: it.pr.draft,
      mergeable: it.pr.mergeable,
      mergeable_state: it.pr.mergeable_state,
    };
  }
  if (apiPath.includes('/check-runs')) {
    return { check_runs: it.pr.checkRuns };
  }
  return {};
}

// -----------------------------------------------------------------------------
// 11. HTTP Server & Route Dispatcher
// -----------------------------------------------------------------------------

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
    });
    req.on('end', () => {
      if (!raw.trim()) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error(`Invalid JSON payload: ${e.message}`));
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const pathname = parsedUrl.pathname;
  const method = req.method || 'GET';

  try {
    // 1. GET /health
    if (method === 'GET' && pathname === '/health') {
      return sendJson(res, 200, {
        ok: true,
        owner: config.owner,
        projectNumber: config.projectNumber,
        repo: config.repo,
        mockMode: config.mockMode,
        cachedBoardItems: state.boardItems.size,
        writeQueueLength: state.writeQueue.length,
        tokens: tokenPool.map((t) => ({
          id: t.id,
          restRemaining: t.restRemaining,
          graphqlRemaining: t.graphqlRemaining,
        })),
        stats: state.stats,
      });
    }

    // 2. GET /poll?status=X&attention=Y&auto_bounce_ci=1&timeout=30
    if (method === 'GET' && pathname === '/poll') {
      const targetStatus = parsedUrl.searchParams.get('status') || '';
      const targetAttention = parsedUrl.searchParams.get('attention') || 'Standard';
      const autoBounceCi = parsedUrl.searchParams.get('auto_bounce_ci') === '1';
      const timeoutSec = Math.min(60, Math.max(1, Number(parsedUrl.searchParams.get('timeout') || 30)));

      if (!targetStatus) {
        return sendJson(res, 400, { ok: false, error: 'Missing status query parameter' });
      }

      const immediate = await findMatchingBoardItem(targetStatus, targetAttention, autoBounceCi);
      if (immediate) {
        return sendJson(res, 200, { matched: true, item: immediate });
      }

      // Hold connection open waiting for instant local write-through or next background sync
      let settled = false;
      const cleanup = () => {
        settled = true;
        clearTimeout(timer);
        bus.removeListener('board-updated', onUpdate);
      };

      const onUpdate = async () => {
        if (settled) return;
        try {
          const found = await findMatchingBoardItem(targetStatus, targetAttention, autoBounceCi);
          if (found && !settled) {
            cleanup();
            sendJson(res, 200, { matched: true, item: found });
          }
        } catch {
          // Ignore transient check errors during long-poll
        }
      };

      const timer = setTimeout(() => {
        if (!settled) {
          cleanup();
          sendJson(res, 200, { matched: false });
        }
      }, timeoutSec * 1000);

      req.on('close', cleanup);
      bus.on('board-updated', onUpdate);
      return;
    }

    // 3. GET /issues/:num or /issues/:num/context
    const issueContextMatch = pathname.match(/^\/issues\/(\d+)(?:\/context)?$/);
    if (method === 'GET' && issueContextMatch) {
      const num = issueContextMatch[1];
      await syncProjectBoard(false);
      const ctx = await getHydratedIssueContext(num);
      return sendJson(res, 200, ctx);
    }

    // 4. PATCH /issues/:num (Update title and/or body via REST = 0 GraphQL points)
    const issuePatchMatch = pathname.match(/^\/issues\/(\d+)$/);
    if (method === 'PATCH' && issuePatchMatch) {
      const num = issuePatchMatch[1];
      const body = await readJsonBody(req);
      const boardItem = state.boardItems.get(num);
      const repo = boardItem?.repo || config.repo;
      if (!repo) return sendJson(res, 400, { ok: false, error: 'Repo not configured' });

      const patchPayload = {};
      if (body.title !== undefined) patchPayload.title = body.title;
      if (body.body !== undefined) patchPayload.body = body.body;

      if (boardItem && body.title) {
        boardItem.title = body.title;
      }

      const updated = await enqueueWrite(async () => {
        const resData = await githubRest(`/repos/${repo}/issues/${num}`, {
          method: 'PATCH',
          body: patchPayload,
        });
        state.etagCache.delete(`https://api.github.com/repos/${repo}/issues/${num}`);
        return resData;
      });

      return sendJson(res, 200, { ok: true, number: Number(num), title: updated?.title || body.title });
    }

    // 5. POST /issues/:num/comment
    const issueCommentMatch = pathname.match(/^\/issues\/(\d+)\/comment$/);
    if (method === 'POST' && issueCommentMatch) {
      const num = issueCommentMatch[1];
      const body = await readJsonBody(req);
      const boardItem = state.boardItems.get(num);
      const repo = boardItem?.repo || config.repo;
      if (!repo || !body.body) {
        return sendJson(res, 400, { ok: false, error: 'Missing repo or comment body' });
      }
      await enqueueWrite(async () => {
        await githubRest(`/repos/${repo}/issues/${num}/comments`, {
          method: 'POST',
          body: { body: body.body },
        });
        state.etagCache.delete(`https://api.github.com/repos/${repo}/issues/${num}/comments?per_page=30`);
      });
      return sendJson(res, 200, { ok: true, number: Number(num) });
    }

    // 6. POST /issues/:num/transition
    const transitionMatch = pathname.match(/^\/issues\/(\d+)\/transition$/);
    if (method === 'POST' && transitionMatch) {
      const num = transitionMatch[1];
      const body = await readJsonBody(req);
      const result = await transitionIssue(num, body);
      return sendJson(res, 200, result);
    }

    // 7. GET /prs/:num/checks?wait=0|1
    const prChecksMatch = pathname.match(/^\/prs\/(\d+)\/checks$/);
    if (method === 'GET' && prChecksMatch) {
      const prNum = prChecksMatch[1];
      const wait = parsedUrl.searchParams.get('wait') === '1';
      const repo = config.repo;
      if (!repo) return sendJson(res, 400, { ok: false, error: 'Repo not configured' });

      const checkOnce = async () => {
        const prData = await githubRest(`/repos/${repo}/pulls/${prNum}`, { ttlMs: 10000 });
        const checks = await fetchPrChecksRest(repo, prData.head?.sha);
        return {
          prNumber: Number(prNum),
          headRefName: prData.head?.ref || '',
          headSha: prData.head?.sha || '',
          mergeable: prData.mergeable,
          mergeableState: prData.mergeable_state || '',
          checks,
        };
      };

      let result = await checkOnce();
      const startWait = Date.now();
      while (wait && result.checks.state === 'pending' && Date.now() - startWait < 300000) {
        await new Promise((r) => setTimeout(r, 20000));
        result = await checkOnce();
      }
      return sendJson(res, 200, result);
    }

    // 8. POST /prs/:num/comment
    const prCommentMatch = pathname.match(/^\/prs\/(\d+)\/comment$/);
    if (method === 'POST' && prCommentMatch) {
      const prNum = prCommentMatch[1];
      const body = await readJsonBody(req);
      const repo = config.repo;
      if (!repo || !body.body) {
        return sendJson(res, 400, { ok: false, error: 'Missing repo or comment body' });
      }
      await enqueueWrite(async () => {
        await githubRest(`/repos/${repo}/issues/${prNum}/comments`, {
          method: 'POST',
          body: { body: body.body },
        });
      });
      return sendJson(res, 200, { ok: true, prNumber: Number(prNum) });
    }

    // 9. POST /prs/:num/review
    const prReviewMatch = pathname.match(/^\/prs\/(\d+)\/review$/);
    if (method === 'POST' && prReviewMatch) {
      const prNum = prReviewMatch[1];
      const body = await readJsonBody(req);
      const repo = config.repo;
      if (!repo || !body.event) {
        return sendJson(res, 400, { ok: false, error: 'Missing repo or review event (APPROVE | REQUEST_CHANGES | COMMENT)' });
      }
      await enqueueWrite(async () => {
        await githubRest(`/repos/${repo}/pulls/${prNum}/reviews`, {
          method: 'POST',
          body: { event: body.event, body: body.body || '' },
        });
      });
      return sendJson(res, 200, { ok: true, prNumber: Number(prNum), event: body.event });
    }

    return sendJson(res, 404, { ok: false, error: `Unknown endpoint: ${method} ${pathname}` });
  } catch (err) {
    return sendJson(res, 500, { ok: false, error: err.message || String(err) });
  }
});

// Background sync loop
const bgTimer = setInterval(() => {
  if (config.owner && config.projectNumber) {
    syncProjectBoard(true).catch(() => {});
  }
}, config.syncIntervalMs);
bgTimer.unref();

server.listen(config.port, config.host, () => {
  console.log(
    `[pipeline-server] Listening on http://${config.host}:${config.port} (owner=${config.owner}, project=#${config.projectNumber}, repo=${config.repo}, tokens=${tokenPool.length})`
  );
  if (config.owner && config.projectNumber) {
    syncProjectBoard(true).catch(() => {});
  }
});

function shutdown() {
  clearInterval(bgTimer);
  server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

#!/usr/bin/env node
/**
 * Custom NVIDIA Nemotron 3 Ultra 550B Pull Request Reviewer for PhysicalAgent
 *
 * Performs deep reasoning architectural and hardware concurrency audits:
 * - Anti-AI-slop (strictly no em-dashes, no filler, concise human phrasing)
 * - Mach-O header integrity (no file offset displacement)
 * - Socket concurrency & thread safety (non-blocking server, async camera)
 * - Apple A5 hardware safety & memory containment (< 50MB RAM)
 */

import { execSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';

const NVIDIA_API_KEY = process.env.NVIDIA_API_KEY;
const GITHUB_TOKEN = process.env.GITHUB_TOKEN;
const PR_NUMBER = process.env.PR_NUMBER;
const REPO = process.env.GITHUB_REPOSITORY;
const BASE_REF = process.env.GITHUB_BASE_REF || 'main';

if (!NVIDIA_API_KEY) {
  console.error('Error: NVIDIA_API_KEY secret is not configured in repository settings. Failing closed.');
  process.exit(1);
}

if (!GITHUB_TOKEN || !PR_NUMBER || !REPO) {
  console.error('Missing required GitHub environment variables (GITHUB_TOKEN, PR_NUMBER, GITHUB_REPOSITORY).');
  process.exit(1);
}

let diff = '';
try {
  const diffRes = await fetch(`https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}`, {
    headers: {
      'Authorization': `Bearer ${GITHUB_TOKEN}`,
      'Accept': 'application/vnd.github.v3.diff',
      'User-Agent': 'PhysicalAgent-CI'
    }
  });
  if (diffRes.ok) {
    diff = await diffRes.text();
  } else {
    throw new Error(`GitHub API diff returned HTTP ${diffRes.status}`);
  }
} catch (apiErr) {
  console.warn('API diff fetch failed, falling back to local git diff:', apiErr.message || apiErr);
  try {
    execSync(`git fetch origin ${BASE_REF}:${BASE_REF} --depth=100`, { stdio: 'inherit' });
    diff = execSync(`git diff ${BASE_REF}...HEAD`, { encoding: 'utf-8', maxBuffer: 10 * 1024 * 1024 });
  } catch (err) {
    console.error('Failed to compute git diff:', err);
    process.exit(1);
  }
}

if (!diff.trim()) {
  console.log('No diff detected against base branch.');
  process.exit(0);
}

function extractVerdict(text) {
  const lines = text.split('\n');
  const verdictMatches = [];

  for (const line of lines) {
    const match = line.match(/^\s*(?:[-*+]\s+)?(?:\*{1,2}|#+)?\s*verdict(?:\*{1,2}|#+)?\s*:\s*(.+)$/i);
    if (!match) continue;

    const rawValue = match[1].trim();
    if (rawValue.includes('|')) continue;

    const cleaned = rawValue.replace(/^[\s\*\[`"'#]+|[\s\*\]`"'#]+$/g, '').trim().toUpperCase();

    if (cleaned === 'APPROVE' || cleaned === 'REQUEST_CHANGES' || cleaned === 'COMMENT') {
      verdictMatches.push(cleaned);
    } else {
      verdictMatches.push(`INVALID:${cleaned}`);
    }
  }

  if (verdictMatches.length === 0) {
    return { verdict: null, reason: 'No valid verdict line found in review output' };
  }

  const invalidMatch = verdictMatches.find((v) => v.startsWith('INVALID:'));
  if (invalidMatch) {
    return { verdict: null, reason: `Unrecognized verdict value: "${invalidMatch.slice(8)}"` };
  }

  if (verdictMatches.includes('REQUEST_CHANGES')) {
    return { verdict: 'REQUEST_CHANGES', reason: 'Reviewer issued REQUEST_CHANGES' };
  }

  const allApproved = verdictMatches.every((v) => v === 'APPROVE');
  if (allApproved) {
    return { verdict: 'APPROVE', reason: null };
  }

  return { verdict: verdictMatches[0], reason: `Non-approving verdict: "${verdictMatches.join(', ')}"` };
}

async function postCommentWithRetry(commentUrl, body, retries = 3) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const postRes = await fetch(commentUrl, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${GITHUB_TOKEN}`,
          'Accept': 'application/vnd.github.v3+json',
          'Content-Type': 'application/json',
          'User-Agent': 'PhysicalAgent-CI'
        },
        signal: AbortSignal.timeout(15000),
        body: JSON.stringify({ body })
      });

      if (postRes.ok) {
        console.log(`Successfully posted review to PR #${PR_NUMBER} (attempt ${attempt})`);
        return true;
      }

      const status = postRes.status;
      const errorText = await postRes.text();
      console.warn(`GitHub API post attempt ${attempt}/${retries} failed (${status}):`, errorText);

      if (status !== 429 && status < 500) {
        return false;
      }
    } catch (err) {
      console.warn(`GitHub API post network error on attempt ${attempt}/${retries}:`, err.message || err);
    }

    if (attempt < retries) {
      const delayMs = Math.pow(2, attempt) * 1000;
      console.log(`Waiting ${delayMs}ms before retry...`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  return false;
}

const MAX_DIFF_CHARS = 300000;
if (diff.length > MAX_DIFF_CHARS) {
  console.warn(`Diff size (${diff.length} chars) exceeds MAX_DIFF_CHARS (${MAX_DIFF_CHARS}). Truncating diff.`);
}
const truncatedDiff = diff.length > MAX_DIFF_CHARS ? diff.slice(0, MAX_DIFF_CHARS) + '\n\n[Diff truncated at 300,000 characters...]' : diff;

const systemPrompt = `You are a Principal Systems Architect and Embedded Security Auditor performing an automated deep reasoning code review on "PhysicalAgent", a native multimodal embodied AI desk companion built for physical iPhone 4S hardware (iOS 6.1.3 ARMv7) communicating with an M5 Mac host over 30-pin USB and Wi-Fi.

YOUR MISSION:
Perform a deep architectural, concurrency, and hardware security review on the provided Git diff. Identify subtle bugs, race conditions, memory leaks, and production anti-patterns.
SCOPE NOTE: Evaluate ONLY the files modified in this PR diff. Files already merged into the base branch (such as tools/fix_macho_ios6.py and PhysicalAgent client) are part of the baseline and out of scope for this review.

STRICT FORMATTING & STYLE RULES:
- Reject any em-dash characters in newly added or modified content (lines starting with '+'). Ignore removed lines (lines starting with '-') since they represent deleted code/text being fixed.
- Avoid generic AI boilerplate, conversational fluff, and sycophantic praise. Keep comments technical, direct, and concise.

AUDIT CRITERIA:
1. HARDWARE CONSTRAINTS & THREAD SAFETY (iOS 6.1.3):
   - PowerVR SGX543MP2 GPU: CALayer transform, bounds, and opacity only. Zero layout thrashing.
   - Memory Budget: Process memory < 50MB; system free RAM >= 150MB.
   - Concurrency: BSD socket server must dispatch clients asynchronously. Never block the main run loop.
   - AVCaptureSession: Lock configuration safety, no session leaks, auto-stop on idle.

2. MACH-O TOOLCHAIN INTEGRITY:
   - Header patching in tools/fix_macho_ios6.py must preserve segment alignments and section file offsets within header padding without shifting __TEXT or __DATA.

3. DUAL-MODE SOCKET RESILIENCE:
   - USB vs Wi-Fi transparent failover with explicit socket timeouts. Zero hanging connections.

OUTPUT FORMAT:
Provide a clear, formatted GitHub Markdown review:
### NVIDIA Nemotron 3 Ultra 550B Deep Reasoning Audit

**Verdict**: [APPROVE | REQUEST_CHANGES | COMMENT]

#### Production Invariants Check
- [x or ] Anti-AI-slop & Human Copy (no em-dashes)
- [x or ] iOS 6 GPU Acceleration & Memory Limits (< 50MB)
- [x or ] Socket Concurrency & Thread Isolation
- [x or ] Mach-O Header Alignment & Toolchain Integrity
- [x or ] Transport Resilience (USB / Wi-Fi failover)

#### Deep Reasoning Findings
(Detail specific architectural risks, subtle race conditions, or edge cases with file paths and line references. If clean, state "No architectural vulnerabilities or race conditions detected. Production invariants satisfied.")
`;

async function getAvailableNvidiaModels(apiKey) {
  try {
    const res = await fetch('https://integrate.api.nvidia.com/v1/models', {
      headers: { 'Authorization': `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(10000)
    });
    if (res.ok) {
      const data = await res.json();
      if (Array.isArray(data?.data)) {
        const ids = data.data.map((m) => m.id);
        const nonChatKeywords = ['embed', 'safety', 'guard', 'reward', 'rerank'];
        const isValidChatModel = (id) => !nonChatKeywords.some((keyword) => id.toLowerCase().includes(keyword));
        const chatModels = ids.filter(isValidChatModel);
        const nemotrons = chatModels.filter((id) => id.includes('nemotron'));
        const others = chatModels.filter((id) => !id.includes('nemotron'));
        return [...nemotrons, ...others];
      }
    }
  } catch (err) {
    console.warn('Could not query NVIDIA NIM models dynamically:', err.message || err);
  }
  return [
    'nvidia/nemotron-3-ultra-550b-a55b',
    'nvidia/nemotron-3.5-lightning-30b-a3b',
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning'
  ];
}

async function runReview() {
  const discoveredModels = await getAvailableNvidiaModels(NVIDIA_API_KEY);
  const preferredModels = [
    'nvidia/nemotron-3-ultra-550b-a55b',
    'nvidia/nemotron-3.5-lightning-30b-a3b',
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning'
  ];
  const candidateModels = [
    ...preferredModels.filter((m) => discoveredModels.includes(m)),
    ...discoveredModels.filter((m) => !preferredModels.includes(m))
  ];

  const url = 'https://integrate.api.nvidia.com/v1/chat/completions';

  let reviewBody = null;
  let lastError = null;

  for (const modelName of candidateModels.slice(0, 5)) {
    console.log(`Sending PR #${PR_NUMBER} diff (${diff.length} bytes) to NVIDIA NIM (${modelName})...`);

    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        if (attempt > 1) {
          console.log(`Retrying Nemotron review on ${modelName} (attempt ${attempt}/2)...`);
        }
        const response = await fetch(url, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${NVIDIA_API_KEY}`,
            'Content-Type': 'application/json'
          },
          signal: AbortSignal.timeout(120000),
          body: JSON.stringify({
            model: modelName,
            messages: [
              { role: 'system', content: systemPrompt },
              { role: 'user', content: `--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${truncatedDiff}` }
            ],
            temperature: 0.1,
            max_tokens: 4096
          })
        });

        if (!response.ok) {
          const errorText = await response.text();
          console.warn(`NVIDIA API error with model ${modelName} (${response.status}):`, errorText);
          lastError = errorText;
          continue;
        }

        const data = await response.json();
        reviewBody = data?.choices?.[0]?.message?.content;
        if (reviewBody) break;
      } catch (err) {
        console.warn(`Nemotron request on ${modelName} attempt ${attempt} failed:`, err.message || err);
        lastError = err.message || err;
      }
    }
    if (reviewBody) break;
  }

  if (!reviewBody) {
    console.error('Nemotron review failed across all candidate models. Last error:', lastError);
    process.exit(1);
  }

  // Post review comment to GitHub PR with exponential backoff retry
  const commentUrl = `https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments`;
  const posted = await postCommentWithRetry(commentUrl, reviewBody);
  if (!posted) {
    console.error(`Failed to post review comment to GitHub PR #${PR_NUMBER} after multiple attempts.`);
    process.exit(1);
  }

  // Extract and validate structured review verdict
  const { verdict, reason } = extractVerdict(reviewBody);

  if (verdict === 'REQUEST_CHANGES') {
    console.error(`Nemotron Auditor issued REQUEST_CHANGES. Gating PR #${PR_NUMBER}.`);
    process.exit(1);
  } else if (verdict === 'APPROVE') {
    console.log(`Nemotron Auditor passed with APPROVE for PR #${PR_NUMBER}.`);
  } else {
    console.error(`Nemotron Auditor verdict was not APPROVE (${reason || `found: "${verdict}"`}). Gating PR #${PR_NUMBER}.`);
    process.exit(1);
  }
}

runReview();

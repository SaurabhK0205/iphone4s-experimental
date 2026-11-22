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
    execSync(`git fetch origin ${BASE_REF} --depth=50`, { stdio: 'inherit' });
    diff = execSync(`git diff origin/${BASE_REF}...HEAD`, { encoding: 'utf-8', maxBuffer: 10 * 1024 * 1024 });
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
  const verdictLines = lines.filter((line) => /^\s*(?:\*{1,2}|#+)?\s*verdict\s*(?:\*{1,2}|#+)?\s*:/i.test(line));
  if (verdictLines.length !== 1) {
    return { verdict: null, reason: `Expected exactly 1 verdict line, found ${verdictLines.length}` };
  }
  const rawLine = verdictLines[0];
  if (rawLine.includes('|')) {
    return { verdict: null, reason: 'Ambiguous template options found in verdict line' };
  }
  const colonIdx = rawLine.indexOf(':');
  const afterColon = rawLine.slice(colonIdx + 1).trim();
  const cleaned = afterColon.replace(/^[\s\*\[`_]+|[\s\*\]`_]+$/g, '').trim().toUpperCase();
  if (cleaned === 'APPROVE' || cleaned === 'REQUEST_CHANGES' || cleaned === 'COMMENT') {
    return { verdict: cleaned, reason: null };
  }
  return { verdict: null, reason: `Unrecognized verdict value: "${cleaned}"` };
}

const MAX_DIFF_CHARS = 250000;
const truncatedDiff = diff.length > MAX_DIFF_CHARS ? diff.slice(0, MAX_DIFF_CHARS) + '\n\n[Diff truncated at 250,000 characters...]' : diff;

const systemPrompt = `You are a Principal Systems Architect and Embedded Security Auditor performing an automated deep reasoning code review on "PhysicalAgent", a native multimodal embodied AI desk companion built for physical iPhone 4S hardware (iOS 6.1.3 ARMv7) communicating with an M5 Mac host over 30-pin USB and Wi-Fi.

YOUR MISSION:
Perform a deep architectural, concurrency, and hardware security review on the provided Git diff. Identify subtle bugs, race conditions, memory leaks, and production anti-patterns.
SCOPE NOTE: Evaluate ONLY the files modified in this PR diff. Files already merged into the base branch (such as tools/fix_macho_ios6.py and PhysicalAgent client) are part of the baseline and out of scope for this review.

STRICT FORMATTING & STYLE RULES:
- NEVER use em-dash characters. Always use colons (:), standard hyphens (-), or parentheses instead.
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
        const nemotrons = ids.filter((id) => id.includes('nemotron'));
        const others = ids.filter((id) => !id.includes('nemotron'));
        return [...nemotrons, ...others];
      }
    }
  } catch (err) {
    console.warn('Could not query NVIDIA NIM models dynamically:', err.message || err);
  }
  return ['nvidia/nemotron-3-ultra-550b-a55b', 'nvidia/nemotron-4-340b-instruct'];
}

async function runReview() {
  const discoveredModels = await getAvailableNvidiaModels(NVIDIA_API_KEY);
  const preferredModels = ['nvidia/nemotron-3-ultra-550b-a55b'];
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
          signal: AbortSignal.timeout(90000),
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

  // Post review comment to GitHub PR
  const commentUrl = `https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments`;
  const postRes = await fetch(commentUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${GITHUB_TOKEN}`,
      'Accept': 'application/vnd.github.v3+json',
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ body: reviewBody })
  });

  if (postRes.ok) {
    console.log(`Successfully posted Nemotron review to PR #${PR_NUMBER}`);
  } else {
    console.error(`Failed to post review comment (${postRes.status}):`, await postRes.text());
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

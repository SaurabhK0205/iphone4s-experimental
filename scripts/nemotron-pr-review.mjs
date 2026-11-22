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
  const rawVerdicts = [];

  for (const line of lines) {
    const match = line.match(/^\s*(?:[-*+]\s+)?(?:\*{1,2}|#+)?\s*verdict(?:\*{1,2}|#+)?\s*:\s*(.+)$/i);
    if (!match) continue;

    const rawValue = match[1].trim();

    if (rawValue.includes('|')) {
      rawVerdicts.push(`TEMPLATE_PLACEHOLDER:${rawValue}`);
      continue;
    }

    const cleaned = rawValue.replace(/^[\s\*\[`"'#]+|[\s\*\]`"'#]+$/g, '').trim().toUpperCase();

    if (cleaned === 'APPROVE' || cleaned === 'REQUEST_CHANGES' || cleaned === 'COMMENT') {
      rawVerdicts.push(cleaned);
    } else {
      rawVerdicts.push(`INVALID:${cleaned}`);
    }
  }

  if (rawVerdicts.length === 0) {
    return { verdict: null, reason: 'No valid verdict line found in review output' };
  }

  if (rawVerdicts.length > 1) {
    return { verdict: null, reason: `Ambiguous review output: multiple verdict lines detected (${rawVerdicts.join(', ')})` };
  }

  const single = rawVerdicts[0];
  if (single.startsWith('TEMPLATE_PLACEHOLDER:')) {
    return { verdict: null, reason: `Unrendered template placeholder verdict: "${single.slice(22)}"` };
  }
  if (single.startsWith('INVALID:')) {
    return { verdict: null, reason: `Unrecognized verdict value: "${single.slice(8)}"` };
  }

  if (single === 'REQUEST_CHANGES') {
    return { verdict: 'REQUEST_CHANGES', reason: 'Reviewer issued REQUEST_CHANGES' };
  }
  if (single === 'APPROVE') {
    return { verdict: 'APPROVE', reason: null };
  }

  return { verdict: single, reason: `Non-approving verdict: "${single}"` };
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
  const commentUrl = `https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments`;
  const errMsg = `### NVIDIA Nemotron 3 Ultra 550B Audit Failed\n\n**Verdict**: REQUEST_CHANGES\n\n#### Diff Exceeds Safety Limit\nThe pull request diff size (${diff.length} characters) exceeds the maximum review limit of ${MAX_DIFF_CHARS} characters. Reviewing truncated diffs is unsafe and strictly prohibited by repository gating rules. Please split this pull request into smaller, reviewable units.`;
  await postCommentWithRetry(commentUrl, errMsg);
  console.error(`Diff size (${diff.length} chars) exceeds MAX_DIFF_CHARS (${MAX_DIFF_CHARS}). Failing closed.`);
  process.exit(1);
}

const systemPrompt = `You are a Principal Systems Architect, Deep Concurrency Specialist, and Security Auditor performing an automated PR review on "PhysicalAgent" (iPhone 4S / iOS 6.1.3 ARMv7 desk companion communicating with host over USB and Wi-Fi).

YOUR MISSION:
Perform a deep reasoning audit on this pull request diff across CI/CD workflows, Node.js scripts, Python tools, and Objective-C native code. Reject functional bugs, real security vulnerabilities, workflow injection, resource leaks, and style violations. Maintain strict technical rigor without hallucinating false positives on standard architectural designs.

REPOSITORY ARCHITECTURE CONTEXT:
- Fork PR Protection: Untrusted fork PRs use 'pull_request_target' strictly gated by maintainer authorization ('safe-to-test' label) and check out the repository's trusted 'base.ref', treating the fork diff purely as data. This is the required secure design.
- Multi-Model Audit Sequencing: 'nemotron_review' declares 'needs: gemini_review' with 'if: always() && !cancelled() && (...)' to run sequentially after Gemini to eliminate concurrent API comment collisions, while ensuring Nemotron audits even if Gemini requests changes.
- Comment Gating: 'issue_comment' triggers verify maintainer status ('OWNER', 'MEMBER', 'COLLABORATOR') before invoking actions.
- Diff Limit: Diffs exceeding MAX_DIFF_CHARS fail closed immediately.

AUDIT CRITERIA & FAILURE MODES:

1. CI/CD WORKFLOWS & ACTION SECURITY:
   - Principle of Least Privilege: minimal top-level and job-level permissions, no excessive write tokens.
   - Script Injection: Flag any unquoted expressions like \${{ github.event... }} evaluated directly in inline shell run blocks.
   - Event Trigger Coverage: Event triggers must match action configs (e.g. 'labeled' included in pr_actions).
   - Dependents & Sequencing: Jobs must not be silently skipped on failure when independent audits are required.

2. LOGIC, PARSER & CONCURRENCY RIGOR:
   - Fail-closed execution: any unexpected status, ambiguous input, or parser failure must exit code 1 / REQUEST_CHANGES.
   - Verdict parser ambiguity: fail closed on multiple verdict lines, pipe-delimited placeholder templates, or malformed suffixes. Exactly one unambiguous verdict line is required.
   - Concurrency & timeouts: explicit timeouts (AbortSignal.timeout), exponential backoffs on 429/5xx, safe async execution.

3. HARDWARE & EMBEDDED INVARIANTS (Apple A5 / iOS 6.1.3 ARMv7):
   - 60 FPS CoreAnimation: Animate CALayer transform, bounds, and opacity only. Zero layout thrashing.
   - Memory Budget: Process memory < 50MB, free system RAM >= 150MB on 512MB device.
   - Socket server: Non-blocking BSD socket server, asynchronous client dispatch. Never block main run loop.
   - Camera safety: AVCaptureSession lifecycle management, auto-stop on idle.
   - Dual-Mode Transport: Transparent USB and Wi-Fi handling, clean recovery on disconnect.

4. REPOSITORY & TOOLCHAIN STANDARDS:
   - Python Virtual Environment: Python scripts must run in '.venv' with explicit environment verification.
   - Mach-O Toolchain: ARMv7 Mach-O header fixes in tools/fix_macho_ios6.py must preserve segment alignments without shifting __TEXT or __DATA.
   - Zero AI Slop: Reject any em-dash characters in newly added or modified content (lines starting with '+'). Ignore removed lines (lines starting with '-') since they represent deleted code/text being fixed. Reject conversational fluff, apologies, and sycophantic praise.

DECISION PROTOCOL:
- If genuine bugs, security flaws, unhandled edge cases, or em-dash violations are found:
  **Verdict**: REQUEST_CHANGES
- If all checks pass, architecture invariants are satisfied, and zero defects exist:
  **Verdict**: APPROVE

OUTPUT FORMAT:
Output MUST contain exactly ONE line specifying the verdict:
**Verdict**: [APPROVE or REQUEST_CHANGES]

Followed by:
#### Deep Reasoning Findings
(Detail specific architectural risks, subtle race conditions, or edge cases with file paths and line references. If clean across all areas, state "No architectural vulnerabilities or race conditions detected. Production invariants satisfied.")

#### Production Invariants Check
- [x or ] CI/CD Workflow Security & Least Privilege
- [x or ] Fail-Closed Robustness & Logic Edge Cases
- [x or ] Anti-AI-slop & Zero Em-Dashes
- [x or ] Hardware & Concurrency Safety
- [x or ] Repository & Toolchain Standards
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
              { role: 'user', content: `--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${diff}` }
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

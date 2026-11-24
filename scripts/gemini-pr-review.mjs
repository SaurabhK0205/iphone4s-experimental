#!/usr/bin/env node
/**
 * Custom Gemini Pull Request Reviewer for PhysicalAgent (iPhone 4S / iOS 6.1.3)
 *
 * Evaluates git diff against strict production standards:
 * - Anti-AI-slop (no em-dashes, no fluff, concise human phrasing)
 * - iOS 6.1.3 ARMv7 hardware constraints (512MB RAM, 60 FPS CoreAnimation)
 * - Concurrency & thread safety (non-blocking BSD socket server, async camera)
 * - Python virtual environment (.venv) discipline
 * - Error handling and fail-closed state
 */

import { execSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';

const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GITHUB_TOKEN = process.env.GITHUB_TOKEN;
const PR_NUMBER = process.env.PR_NUMBER;
const REPO = process.env.GITHUB_REPOSITORY;
const BASE_REF = process.env.GITHUB_BASE_REF || 'main';

if (!GEMINI_API_KEY) {
  console.error('Error: GEMINI_API_KEY secret is not configured in repository settings. Failing closed.');
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
  const errMsg = `### Gemini Code Auditor Review Gate Failed\n\n**Verdict**: REQUEST_CHANGES\n\n#### Diff Exceeds Safety Limit\nThe pull request diff size (${diff.length} characters) exceeds the maximum review limit of ${MAX_DIFF_CHARS} characters. Reviewing truncated diffs is unsafe and strictly prohibited by repository gating rules. Please split this pull request into smaller, reviewable units.`;
  await postCommentWithRetry(commentUrl, errMsg);
  console.error(`Diff size (${diff.length} chars) exceeds MAX_DIFF_CHARS (${MAX_DIFF_CHARS}). Failing closed.`);
  process.exit(1);
}

const systemPrompt = `You are a Principal Security Architect and Embedded Systems Engineer performing an automated PR review on "PhysicalAgent" (iPhone 4S / iOS 6.1.3 ARMv7 desk companion).

YOUR MISSION:
Audit this pull request diff across CI/CD workflows, Node.js scripts, Python tools, and Objective-C native code. Reject functional bugs, real security vulnerabilities, workflow injection, resource leaks, and style violations. Maintain strict technical rigor without hallucinating false positives on standard architectural designs.

REPOSITORY ARCHITECTURE CONTEXT:
- Fork PR Protection: Untrusted fork PRs use 'pull_request_target' strictly gated by maintainer authorization ('safe-to-test' label) and check out the repository's trusted 'base.ref', treating the fork diff purely as data. This is the required secure design.
- Multi-Model Audit Sequencing: 'nemotron_review' declares 'needs: gemini_review' with 'if: always() && !cancelled() && (...)' to run sequentially after Gemini to eliminate concurrent API comment collisions, while ensuring Nemotron audits even if Gemini requests changes.
- Comment Gating: 'issue_comment' triggers verify maintainer status ('OWNER', 'MEMBER', 'COLLABORATOR') before invoking actions.
- Diff Limit: Diffs exceeding MAX_DIFF_CHARS fail closed immediately.

AUDIT CHECKLIST & SEVERITY RULES:

1. CI/CD & GITHUB ACTIONS SECURITY:
   - Principle of Least Privilege: Workflows must specify minimal top-level and job-level permissions.
   - Script Injection: Flag any unquoted expressions like \${{ github.event... }} evaluated directly in inline shell run blocks.
   - Event Trigger Coverage: Event triggers must match action configs (e.g. 'labeled' included in pr_actions).
   - Dependents & Sequencing: Jobs must not be silently skipped on failure when independent audits are required.

2. LOGIC, PARSER & EDGE-CASE ROBUSTNESS:
   - Fail-Closed Discipline: In error paths, missing configs, or ambiguous outputs, the system MUST fail closed (exit code 1 or REQUEST_CHANGES). Never silently ignore errors or fall through to APPROVE.
   - Verdict Parser Ambiguity: Verdict parsers must reject multiple verdict lines, unrendered placeholders with pipe delimiters, or malformed suffixes. Exactly one unambiguous verdict line is required.
   - Concurrency & Async: Network calls must enforce explicit timeouts (AbortSignal.timeout), proper retry backoffs, and robust error handling.

3. EMBEDDED & HARDWARE INVARIANTS (Apple A5 / iOS 6.1.3 ARMv7):
   - 60 FPS CoreAnimation: Animate CALayer transform, bounds, and opacity only. Zero main-thread layout thrashing.
   - Memory Budget: Process memory < 50MB, maintaining >= 150MB free system RAM on 512MB device.
   - Socket Concurrency: BSD socket server must handle client connections asynchronously on background queues.
   - Camera Sensor Safety: AVCaptureSession must be safely stopped when idle to protect camera sensor from heat and battery drain.

4. REPOSITORY & TOOLCHAIN STANDARDS:
   - Python Virtual Environment: Python scripts must run within '.venv' and verify virtual environment isolation.
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
#### Audit Findings
(Enumerate genuine flaws with file path, line number, bug description, and suggested fix. If clean, state "No critical issues detected. Production standards satisfied.")

#### Production Invariants Check
- [x or ] CI/CD Workflow Security & Least Privilege
- [x or ] Fail-Closed Robustness & Logic Edge Cases
- [x or ] Anti-AI-slop & Zero Em-Dashes
- [x or ] Hardware & Concurrency Safety
- [x or ] Repository & Toolchain Standards
`;

async function getAvailableModels(apiKey) {
  try {
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?key=${apiKey}`, {
      signal: AbortSignal.timeout(10000),
    });
    if (res.ok) {
      const data = await res.json();
      if (Array.isArray(data?.models)) {
        const supported = data.models
          .filter((m) => Array.isArray(m.supportedGenerationMethods) && m.supportedGenerationMethods.includes('generateContent'))
          .map((m) => m.name.replace(/^models\//, ''));
        if (supported.length > 0) {
          const flashModels = supported.filter((m) => m.includes('flash'));
          const otherModels = supported.filter((m) => !m.includes('flash'));
          return [...flashModels, ...otherModels];
        }
      }
    }
  } catch (err) {
    console.warn('Could not query model list, falling back to static list:', err.message || err);
  }
  return ['gemini-2.5-flash', 'gemini-2.0-flash', 'gemini-1.5-flash'];
}

async function runReview() {
  const preferredModels = [
    'gemini-3-flash-preview',
    'gemini-flash-latest'
  ];
  let candidateModels = [...preferredModels];

  let reviewBody = null;
  let lastError = null;

  for (const modelName of candidateModels) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${modelName}:generateContent?key=${GEMINI_API_KEY}`;
    console.log(`Sending PR #${PR_NUMBER} diff to Gemini API (${modelName})...`);

    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(60000),
        body: JSON.stringify({
          contents: [
            {
              role: 'user',
              parts: [
                { text: `${systemPrompt}\n\n--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${diff}` }
              ]
            }
          ],
          generationConfig: {
            temperature: 0.1,
            maxOutputTokens: 8192
          }
        })
      });

      if (!response.ok) {
        const errorText = await response.text();
        console.warn(`Gemini API error with model ${modelName} (${response.status}):`, errorText);
        lastError = errorText;
        continue;
      }

      const data = await response.json();
      reviewBody = data?.candidates?.[0]?.content?.parts?.[0]?.text;
      if (reviewBody) break;
    } catch (err) {
      console.warn(`Gemini model ${modelName} failed:`, err.message || err);
      lastError = err.message || err;
    }
  }

  // If preferred static models failed, try dynamic discovery as backup
  if (!reviewBody) {
    console.log('Preferred models failed, attempting dynamic model discovery...');
    const discoveredModels = await getAvailableModels(GEMINI_API_KEY);
    for (const modelName of discoveredModels) {
      if (preferredModels.includes(modelName)) continue;
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${modelName}:generateContent?key=${GEMINI_API_KEY}`;
      console.log(`Retrying with discovered model (${modelName})...`);
      try {
        const response = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          signal: AbortSignal.timeout(60000),
          body: JSON.stringify({
            contents: [
              {
                role: 'user',
                parts: [
                  { text: `${systemPrompt}\n\n--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${diff}` }
                ]
              }
            ],
            generationConfig: {
              temperature: 0.1,
              maxOutputTokens: 8192
            }
          })
        });
        if (response.ok) {
          const data = await response.json();
          reviewBody = data?.candidates?.[0]?.content?.parts?.[0]?.text;
          if (reviewBody) break;
        }
      } catch (err) {
        console.warn(`Discovered model ${modelName} failed:`, err.message || err);
      }
    }
  }

  if (!reviewBody) {
    console.error('All candidate Gemini models failed. Last error:', lastError);
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
    console.error(`Gemini Code Auditor issued REQUEST_CHANGES. Gating PR #${PR_NUMBER}.`);
    process.exit(1);
  } else if (verdict === 'APPROVE') {
    console.log(`Gemini Code Auditor passed with APPROVE for PR #${PR_NUMBER}.`);
  } else {
    console.error(`Gemini Code Auditor verdict was not APPROVE (${reason || `found: "${verdict}"`}). Gating PR #${PR_NUMBER}.`);
    process.exit(1);
  }
}

runReview();

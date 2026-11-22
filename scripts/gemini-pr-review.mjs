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

const MAX_DIFF_CHARS = 300000;
const truncatedDiff = diff.length > MAX_DIFF_CHARS ? diff.slice(0, MAX_DIFF_CHARS) + '\n\n[Diff truncated at 300,000 characters...]' : diff;

const systemPrompt = `You are a Principal Embedded Systems Engineer and Staff Security Auditor performing an automated PR review on "PhysicalAgent", a native multimodal embodied AI companion running on physical iPhone 4S hardware (iOS 6.1.3 ARMv7).

YOUR MISSION:
Ensure ONLY production-grade, hardware-safe, reliable code is merged. Actively eliminate AI slop, conversational filler, race conditions, and memory leaks.

REVIEW CRITERIA:
1. STRICT ANTI-AI-SLOP:
   - Reject any em-dash characters in code, strings, documentation, or messages. Use hyphens, colons, or parentheses.
   - Reject conversational fluff, apologies, sycophantic praise, and generic AI templates.

2. HARDWARE CONSTRAINTS (Apple A5 / iOS 6.1.3):
   - 60 FPS CoreAnimation: Animate CALayer transform, bounds, and opacity only. Zero layout thrashing.
   - Memory Budget: Process memory < 50MB, maintaining >= 150MB free system RAM at all times.
   - AVCaptureSession: Must be safely stopped when idle to protect the camera sensor from heat and battery drain.

3. CONCURRENCY & SOCKET INTEGRITY:
   - Socket server must never block the main UI thread. Client connections must be handled on background queues.
   - All network calls on the host Python SDK must enforce explicit socket timeouts.

4. DUAL-MODE TRANSPORT:
   - Host bridge must cleanly handle both 30-pin USB (usbmuxd) and Wi-Fi without crashes on disconnect.

OUTPUT FORMAT:
Provide a clear, formatted GitHub Markdown review:
### Gemini Production Quality Review

**Verdict**: [APPROVE | REQUEST_CHANGES | COMMENT]

#### Production Invariants Check
- [x or ] Anti-AI-slop & Human Copy (no em-dashes, concise copy)
- [x or ] iOS 6 GPU & Memory Bounds (CALayer transform/opacity, <50MB RAM)
- [x or ] Socket Concurrency & Non-blocking Main Thread
- [x or ] Camera Hardware Safety & Auto-Exposure
- [x or ] Python Virtual Environment (.venv) Discipline

#### Findings & Recommendations
(List specific actionable findings with file paths, or state "No critical issues detected. Production standards satisfied." if clean.)
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
    'gemini-flash-lite-latest',
    'gemini-2.0-flash',
    'gemini-2.5-flash',
    'gemini-1.5-flash',
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
        signal: AbortSignal.timeout(25000),
        body: JSON.stringify({
          contents: [
            {
              role: 'user',
              parts: [
                { text: `${systemPrompt}\n\n--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${truncatedDiff}` }
              ]
            }
          ],
          generationConfig: {
            temperature: 0.1,
            maxOutputTokens: 4096
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
          signal: AbortSignal.timeout(25000),
          body: JSON.stringify({
            contents: [
              {
                role: 'user',
                parts: [
                  { text: `${systemPrompt}\n\n--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${truncatedDiff}` }
                ]
              }
            ],
            generationConfig: {
              temperature: 0.1,
              maxOutputTokens: 4096
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
    console.log(`Successfully posted Gemini review to PR #${PR_NUMBER}`);
  } else {
    console.error(`Failed to post review comment (${postRes.status}):`, await postRes.text());
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

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
  console.log('Notice: NVIDIA_API_KEY secret is not configured. Skipping Nemotron automated PR review.');
  process.exit(0);
}

if (!GITHUB_TOKEN || !PR_NUMBER || !REPO) {
  console.error('Missing required GitHub environment variables (GITHUB_TOKEN, PR_NUMBER, GITHUB_REPOSITORY).');
  process.exit(1);
}

let diff = '';
try {
  execSync(`git fetch origin ${BASE_REF} --depth=50`, { stdio: 'inherit' });
  diff = execSync(`git diff origin/${BASE_REF}...HEAD`, { encoding: 'utf-8', maxBuffer: 10 * 1024 * 1024 });
} catch (err) {
  console.error('Failed to compute git diff:', err);
  process.exit(1);
}

if (!diff.trim()) {
  console.log('No diff detected against base branch.');
  process.exit(0);
}

const truncatedDiff = diff.length > 100000 ? diff.slice(0, 100000) + '\n\n[Diff truncated...]' : diff;

const systemPrompt = `You are a Principal Systems Architect and Embedded Security Auditor performing an automated deep reasoning code review on "PhysicalAgent", a native multimodal embodied AI desk companion built for physical iPhone 4S hardware (iOS 6.1.3 ARMv7) communicating with an M5 Mac host over 30-pin USB and Wi-Fi.

YOUR MISSION:
Perform a deep architectural, concurrency, and hardware security review on the provided Git diff. Identify subtle bugs, race conditions, memory leaks, and production anti-patterns.

STRICT FORMATTING & STYLE RULES:
- NEVER use em-dashes (—). Always use colons (:), standard hyphens (-), or parentheses instead.
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

async function runReview() {
  const modelName = 'nvidia/nemotron-3-ultra-550b-a55b';
  const url = 'https://integrate.api.nvidia.com/v1/chat/completions';

  console.log(`Sending PR #${PR_NUMBER} diff (${diff.length} bytes) to NVIDIA NIM (${modelName})...`);

  let reviewBody = null;
  let lastError = null;

  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      if (attempt > 1) {
        console.log(`Retrying Nemotron review (attempt ${attempt}/2)...`);
      }
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${NVIDIA_API_KEY}`,
          'Content-Type': 'application/json'
        },
        signal: AbortSignal.timeout(75000),
        body: JSON.stringify({
          model: modelName,
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: `--- GIT DIFF FOR PULL REQUEST #${PR_NUMBER} ---\n\n${truncatedDiff}` }
          ],
          temperature: 0.1,
          max_tokens: 2048
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
      console.warn(`Nemotron request attempt ${attempt} failed:`, err.message || err);
      lastError = err.message || err;
    }
  }

  if (!reviewBody) {
    console.error('Nemotron review failed after attempts. Last error:', lastError);
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
}

runReview();

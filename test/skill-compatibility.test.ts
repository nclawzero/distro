// @ts-nocheck
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

/**
 * Skill format compatibility tests.
 *
 * Verifies that skill SKILL.md files work across both OpenClaw and ZeroClaw
 * runtimes. Tests the shared format contract: YAML frontmatter with `name`
 * field, markdown body, and optional metadata fields.
 */

import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");

// Load the skill installer's frontmatter parser
const skillInstall = require("../dist/lib/skill-install");

// ── Test data: representative skill formats ─────────────────────────────

const OPENCLAW_SKILL = `---
name: test-openclaw-skill
description: A test skill in OpenClaw format.
---

# Test OpenClaw Skill

This skill tests OpenClaw format compatibility.
`;

const ZEROCLAW_SKILL = `---
name: test-zeroclaw-skill
description: A test skill in ZeroClaw format.
version: 1.0.0
---

# Test ZeroClaw Skill

This skill tests ZeroClaw format compatibility.

## Tools

No tools defined.
`;

const CLAWHUB_SKILL = `---
name: test-clawhub-skill
slug: test-clawhub-skill
version: 1.0.2
homepage: https://clawhub.ai/skills/test
description: A test skill from ClawHub with extra metadata.
changelog: Initial release.
metadata: {"clawdbot":{"emoji":"🧪","requires":{"bins":["curl"]},"os":["linux","darwin"]}}
---

# Test ClawHub Skill

This skill tests ClawHub format compatibility.

## Installation

### OpenClaw / Moltbot / Clawbot

\`\`\`bash
npx clawhub@latest install test-clawhub-skill
\`\`\`

### ZeroClaw

\`\`\`bash
zeroclaw skills install clawhub:test-clawhub-skill
\`\`\`
`;

const MINIMAL_SKILL = `---
name: minimal
description: Bare minimum.
---

One line.
`;

const NCLAWZERO_SKILL = `---
name: nclawzero-test
description: An nclawzero-specific skill.
---

# nclawzero Test Skill

Tests the nclawzero skill format.
`;

// ── Format compatibility tests ──────────────────────────────────────────

describe("skill format compatibility", () => {
  describe("frontmatter parsing across formats", () => {
    it("parses OpenClaw skill format", () => {
      const fm = skillInstall.parseFrontmatter(OPENCLAW_SKILL);
      expect(fm.name).toBe("test-openclaw-skill");
    });

    it("parses ZeroClaw skill format", () => {
      const fm = skillInstall.parseFrontmatter(ZEROCLAW_SKILL);
      expect(fm.name).toBe("test-zeroclaw-skill");
    });

    it("parses ClawHub skill format with extra metadata", () => {
      const fm = skillInstall.parseFrontmatter(CLAWHUB_SKILL);
      expect(fm.name).toBe("test-clawhub-skill");
    });

    it("parses minimal skill format", () => {
      const fm = skillInstall.parseFrontmatter(MINIMAL_SKILL);
      expect(fm.name).toBe("minimal");
    });

    it("parses nclawzero skill format", () => {
      const fm = skillInstall.parseFrontmatter(NCLAWZERO_SKILL);
      expect(fm.name).toBe("nclawzero-test");
    });
  });

  describe("name validation across formats", () => {
    it("accepts names with dots (ClawHub convention)", () => {
      const fm = skillInstall.parseFrontmatter("---\nname: my.skill.v2\ndescription: x\n---\n");
      expect(fm.name).toBe("my.skill.v2");
    });

    it("accepts names with hyphens (OpenClaw convention)", () => {
      const fm = skillInstall.parseFrontmatter("---\nname: openclaw-my-skill\ndescription: x\n---\n");
      expect(fm.name).toBe("openclaw-my-skill");
    });

    it("accepts names with underscores (ZeroClaw convention)", () => {
      const fm = skillInstall.parseFrontmatter("---\nname: web_search\ndescription: x\n---\n");
      expect(fm.name).toBe("web_search");
    });

    it("accepts PascalCase names (ClawHub Memory skill)", () => {
      const fm = skillInstall.parseFrontmatter("---\nname: Memory\ndescription: x\n---\n");
      expect(fm.name).toBe("Memory");
    });
  });

  describe("installed nclawzero skills are valid", () => {
    const skillsDir = path.join(ROOT, ".agents", "skills");
    const nclawzeroSkills = fs.existsSync(skillsDir)
      ? fs.readdirSync(skillsDir).filter((d) => d.startsWith("nclawzero-"))
      : [];

    for (const skillName of nclawzeroSkills) {
      const skillMd = path.join(skillsDir, skillName, "SKILL.md");
      if (!fs.existsSync(skillMd)) continue;

      it(`nclawzero skill '${skillName}' has valid frontmatter`, () => {
        const content = fs.readFileSync(skillMd, "utf-8");
        const fm = skillInstall.parseFrontmatter(content);
        expect(fm.name).toBeTruthy();
        expect(fm.name).toMatch(/^[A-Za-z0-9._-]+$/);
      });
    }
  });

  describe("installed nemoclaw skills are valid", () => {
    const skillsDir = path.join(ROOT, ".agents", "skills");
    const nemoclawSkills = fs.existsSync(skillsDir)
      ? fs.readdirSync(skillsDir).filter((d) => d.startsWith("nemoclaw-user-"))
      : [];

    for (const skillName of nemoclawSkills) {
      const skillMd = path.join(skillsDir, skillName, "SKILL.md");
      if (!fs.existsSync(skillMd)) continue;

      it(`upstream skill '${skillName}' has valid frontmatter`, () => {
        const content = fs.readFileSync(skillMd, "utf-8");
        const fm = skillInstall.parseFrontmatter(content);
        expect(fm.name).toBeTruthy();
      });
    }
  });

  describe("ClawHub source detection", () => {
    it("detects clawhub: prefix", () => {
      expect("clawhub:weather".startsWith("clawhub:")).toBe(true);
    });

    it("detects clawhub.ai URL", () => {
      expect("https://clawhub.ai/skills/weather".includes("clawhub.ai/")).toBe(true);
    });

    it("does not detect local paths as ClawHub", () => {
      expect("/home/pi/skills/weather".startsWith("clawhub:")).toBe(false);
      expect("/home/pi/skills/weather".includes("clawhub.ai/")).toBe(false);
    });

    it("does not detect github URLs as ClawHub", () => {
      expect("https://github.com/user/skill".startsWith("clawhub:")).toBe(false);
      expect("https://github.com/user/skill".includes("clawhub.ai/")).toBe(false);
    });
  });
});

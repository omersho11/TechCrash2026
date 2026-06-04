---
name: Git Development Flow & Fork Rules
description: Guidelines on using the Development branch as the main fork branch and redirecting pull requests to prevent upstream submissions.
---

# Git Development Flow & Fork Rules

This document outlines the branching and contribution workflow when working within this fork repository (`omersho11/TechCrash2026`).

---

## Branching Model

The primary branch for all ongoing development is `Development`.

1. **Primary Branch**: `Development` acts as the primary code integration target.
2. **Feature Branches**: All new features, challenge solutions, and tests must be created from `Development` (e.g. `feature-challenge-06`).
3. **Merging**: Pull Requests should target your fork's `Development` branch, not `main` or the upstream `main`.

---

## How to Avoid Pull Requests to Upstream Repo

Because this repository is a fork of `avisalmon/TechCrash2026`, GitHub will by default try to target the upstream base repository when creating a Pull Request. To avoid this:

### 1. Direct Compare Links
Always use comparison URLs configured for your fork to bypass upstream target suggestions:
- Compare feature branch to your Development branch:
  `https://github.com/omersho11/TechCrash2026/compare/Development...<your-feature-branch>`

### 2. Manual Target Selection in GitHub UI
When creating a pull request in the GitHub Web UI:
- **Left side (base repository)**: Change from `avisalmon/TechCrash2026` to `omersho11/TechCrash2026`.
- **Left side (base branch)**: Change from `main` to `Development`.
- **Right side (compare branch)**: Select your feature branch.

### 3. detaching the Fork (GitHub Support)
To permanently remove the option to submit pull requests to the upstream repository, you can contact GitHub Support and request to **"detach the fork"**. This turns your repository into a standalone repository while keeping all your commits and branches.
- Link: [GitHub Support](https://support.github.com/)

---

## Local Git Configurations

Keep the upstream remote configuration so you can fetch updates from the master repository without pushing to it:

```powershell
# Add upstream remote if not already present
git remote add upstream https://github.com/avisalmon/TechCrash2026.git

# Pull updates from original repo to your Development branch
git checkout Development
git fetch upstream
git merge upstream/main
```

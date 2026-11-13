---
title: Docs Deployment
noindex: true
description: How the documentation site is built and deployed.
nav_order: 3
---

The docs live in `docs/` and use `jekyll-vitepress-theme`.

Local build:

```sh
cd docs
bundle install
bundle exec jekyll build
```

Local server:

```sh
cd docs
bundle exec jekyll serve --livereload
```

GitHub Actions builds the docs on pull requests. On pushes to the repository default branch, it uploads the built site with `actions/upload-pages-artifact` and deploys it with `actions/deploy-pages`.

No `gh-pages` branch is used.

# Changelog

## [0.4.0](https://github.com/hir4ta/mumei/compare/v0.3.9...v0.4.0) (2026-05-09)


### Features

* **ci:** adopt release-please for monorepo release automation ([#19](https://github.com/hir4ta/mumei/issues/19)) ([a4775ba](https://github.com/hir4ta/mumei/commit/a4775ba56c699bb15e24a77590b7d3c5e74817ad))


### Bug Fixes

* **ci:** address Copilot review on [#19](https://github.com/hir4ta/mumei/issues/19) + CodeQL TokenPermissionsID [#48](https://github.com/hir4ta/mumei/issues/48) ([#20](https://github.com/hir4ta/mumei/issues/20)) ([dea480c](https://github.com/hir4ta/mumei/commit/dea480c3076fe7890388d9d216372d0494f90e0c))
* **dashboard:** featureKey allowlist guard at public API entry (CodeQL js/path-injection) ([79cfbd6](https://github.com/hir4ta/mumei/commit/79cfbd6b9a4ef64cd6f3befa8ede77054f3d4957))
* **dashboard:** inline sanitizer for path-injection + docs for branch protection ([#18](https://github.com/hir4ta/mumei/issues/18)) ([7b49834](https://github.com/hir4ta/mumei/commit/7b49834335f319058da6e87803db466ad457a4f4))
* **lint:** ignore CHANGELOG.md (release-please auto-generates with multi-blank-lines) ([#24](https://github.com/hir4ta/mumei/issues/24)) ([1e24b14](https://github.com/hir4ta/mumei/commit/1e24b14ff0124e7f479b3b91cd56021f588db8f8))


### Reverts

* drop code-scanning-issue.yml — code_scanning_alert is not an Actions trigger event ([14cfc15](https://github.com/hir4ta/mumei/commit/14cfc156e2e10b1048299de3988df5b6517b1b20))

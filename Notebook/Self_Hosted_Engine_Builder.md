# Self-hosted engine builder

The engine build workflow is a manually dispatched production-only workflow on a dedicated macOS runner labeled `shaar-engine`. It has no pull request or push trigger and permits one build at a time. Its job guard rejects dispatches from other refs before they reach the runner. It checks out the selected production commit into `~/shaar-engine-cache/shaar`, outside the runner's per-job workspace, where the builder's owner-checked `build/EngineSource` tree persists between runs. The package is uploaded as a seven-day Actions artifact; the workflow does not create releases or tags.

The cache contains executable source and a large generated Chromium tree. Keep it private to the runner account (`0700`), use a dedicated account/Mac with FileVault and current macOS security updates, and do not run ordinary agents, pull request jobs, or unrelated code on the runner. The build uses scripts from the production commit only. Do not weaken the production-ref guard or add `pull_request`, `pull_request_target`, or fork push triggers.

Before registration, an organization owner must provide a runner group that allows the public `arcusis/shaar` repository and restricts access to exactly `arcusis/shaar/.github/workflows/engine-build.yml@refs/heads/production`. Add the runner to that group, not a broad/default group. The current `Arcusis macOS` group does not allow public repositories and its workflow restriction setting is read-only; coordinate an eligible group before attaching David's Mac. Keep repository Actions workflow permissions read-only and limit workflow dispatch to trusted maintainers.

Registration steps for the coordinator:

1. In `arcusis/shaar` Settings → Actions → Runners, choose **New self-hosted runner**, select macOS and ARM64, and copy the fresh one-time registration token and displayed commands.
2. Use a dedicated macOS runner account. In the registration command, select the pre-approved runner group, set the runner name to identify David's office Mac, and add labels `shaar-engine` (GitHub supplies `self-hosted` and `macOS`). Do not put the one-time token in a PR, issue, or shell history.
3. Install and start the runner as a service for that dedicated account. Confirm it appears online in the approved group and that the group grants access only to the production workflow above.
4. From the `production` branch, a trusted maintainer manually dispatches **Self-hosted engine build**. Review the artifact and build receipt in Actions; there is no release or tag step.

The repository fork-PR workflow approval setting was `all_external_contributors` when checked for this setup. That setting is not a runner safety boundary: no workflow from a fork may be allowed to execute on this machine.

Related: [[Engine_Source_Build]], [[CI_Pipeline]], [[Notebook_Maintenance]].

# Release the distribution

Merging the release-please pull request into protected `main` authorizes publication.
Review its dated `Changes` entry and the proposed version before merging.
For example, Git tag `v0.1.0` corresponds to Perl version `0.001` and the archive `Test-Mutation-0.001.tar.gz`.
After the merge, the workflow checks the release commit and submits the verified archive to the Perl Authors Upload Server (PAUSE).
It compares the bytes on the Comprehensive Perl Archive Network (CPAN) with the verified archive before publishing the GitHub draft.

## Check a branch before pushing

From a clean checkout, run `mise run check-ci`.
The command runs the fast checks on the pinned Perl and repeats the pull request's driver and shim tests in Linux containers.

## Check the candidate before merging

Use a separate checkout for the release proposal so you can continue working during the local checks.
The local release gate checks the whole mutation inventory, test coverage, supported interpreters, and real Perl distributions.
The gate builds the archive, runs `make disttest`, and tests a fresh installation.

```sh
git fetch origin release-please--branches--main
candidate_sha=$(git rev-parse FETCH_HEAD)
git worktree add --detach ../Test-Mutation-release "$candidate_sha"
cd ../Test-Mutation-release
mise trust
mise run setup
mise run record-release-check
```

To shorten the measurement, set `TEST_MUTATION_DETECTOR_DIR` to a directory outside the checkout containing earlier JSON reports.
The current measurement runs every original test and checks every mutant.
An earlier detection can only suggest which covering test to try first.
The gate prefers an exact mutant ID.
If an edit moves a mutant, the gate matches its span, mutator, and replacement within unchanged source lines.
The matching text includes up to two lines on each side and must occur once in each version of the same file.

The recording task sets the `release/local` commit status using your GitHub CLI account.
GitHub verifies that the repository account recorded the status and installs the archive on Linux and macOS.
A release proposal with changed content needs a fresh local check.
Run the hosted checks with the candidate commit and its expected Perl version before merging.

```sh
gh workflow run release-credentials.yml --ref main
gh workflow run release-gate.yml --ref main -f source_sha="$candidate_sha" -f version=0.001
```

The credential check confirms that the release-please GitHub App can read the repository.
For PAUSE it checks token delivery, local token format, the public `YASUNOBU` account, and indexing permissions for `Test::Mutation`.
PAUSE authenticates the token only during submission.

## Renew credentials

The Doppler project `test-mutation` stores `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_PRIVATE_KEY` in the `release_please` config and `PAUSE_TOKEN` in the `cpan` config.
The GitHub environments `release-please` and `cpan` each use a read-only `DOPPLER_TOKEN` for the corresponding config.
Before the upload token expires, sign in to PAUSE as `YASUNOBU`, select **Generate a New Token**, and replace `PAUSE_TOKEN` in the publishing config.
Run the credential check after rotation.

## Recover an interrupted submission

Use the original merge workflow run and the archive attached to its GitHub draft.
The attached `.sha256` file records a reserved submission that may still be pending at PAUSE.
Rerunning the failed job compares the digest of the public bytes with the original digest.
The [publication adapter](../xt/release-publish/README.md) describes the reconciliation exit codes.

While the public archive is missing, sign in as `YASUNOBU`, check the acknowledgement email, and inspect **Repair a Pending Upload**.
Wait for an accepted upload to reach the mirror and rerun the failed job.
If the status is unclear, ask the PAUSE administrators whether PAUSE accepted the exact filename.
If they confirm PAUSE received no submission, download the archive and its checksum from the draft.
Verify the checksum in the download directory with `shasum -a 256 -c Test-Mutation-0.001.tar.gz.sha256` for the example version.
An authorized maintainer can then submit the verified archive once through **Upload a file to CPAN**.
Run `gh run rerun "$merge_run_id" --failed` to confirm the public digest and finish the GitHub release.
Keep the tag, draft archive, and checksum intact throughout recovery.

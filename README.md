# nixbuild-checks

Experimental action for creating Check Runs to run asynchrounous builds on
nixbuild.net. This action may be integrated into
[nixbuild-action](https://github.com/nixbuild/nixbuild-action) in the future, or
not.

This action is work in progress, and so is the nixbuild.net parts (the API and
the web UI). If you try it out, feel free open issues in this repository or
contact support@nixbuild.net directly with feedback.

## Overview

This action is similar to the [reusable CI workflow in
nixbuild-action](https://github.com/nixbuild/nixbuild-action#using-the-ci-workflow)
in the way it automatically evaluates and builds Nix Flake outputs. However, in
contrast to that action, this action schedules builds asynchronously on
nixbuild.net. That way, no GitHub Actions minutes are wasted when waiting for
builds to finish in nixbuild.net.

The way this is done is through a new experimental API in nixbuild.net that
allows for scheduling asyncronous runs, along with the ability in nixbuild.net
to create GitHub [Check Runs](https://docs.github.com/en/rest/checks/runs).

In brief, the action works like this (see next sections for more details):

1. A commit or PR will trigger your workflow that uses this action.

2. This action evaluates your Nix Flake and asks nixbuild.net to build the
   outputs.

3. Your workflow is now done, an no more GitHub Actions minutes are consumed.

4. nixbuild.net will call out to GitHub to create Check Runs for the derivations
   that was submitted. A GitHub App is used to allow for creating Check Runs in
   your repository. OIDC is used to verify that the build request actually
   originated inside GitHub Actions for your repository. The checks will appear
   on the commit that triggered the initial workflow, and they will start out
   as "in progress" (yellow). If you click on a check you will see a link to
   nixbuild.net's web UI showing the builds that are in progress for the check.

5. nixbuild.net runs the necessary builds and substitutions needed for your
   derivations and will then report back statuses (pass or fail) for the checks.
   You will be able to find build logs by clicking on a check and then following
   the link to the nixbuild.net web UI.

## Usage

1. Install the nixbuild.net [GitHub App](https://github.com/apps/nixbuild-net)
   on the repositories you wish to run nixbuild.net builds on. The app will
   only ask for permissions to read and write Check Runs.

2. Create a nixbuild.net
   [auth token](https://docs.nixbuild.net/access-control/#using-auth-tokens)
   with the permissions `build:read`, `build:write`, `store:read` and
   `store:write`. If you want, you can further attenuate the token to make use
   of [GitHub OIDC](https://blog.nixbuild.net/posts/2025-09-01-oidc-support-in-nixbuild-net.html).
   Store the (possibly attenuated) token as a secret for your GitHub repository.

3. Add a workflow that looks something like below. You need to have a Nix Flake
   in your repository. Don't forget to include the `id-token: write` as below.
   It is used for the OIDC verification.

   ```
   package_builds:
     name: "🚧 Package Builds"
     runs-on: ubuntu-latest
     permissions:
       id-token: write
       contents: read
     steps:
       - name: Install Nix
         uses: nixbuild/nix-quick-install-action@v34
         with:
           nix_version: '2.31.2'

       - name: Setup nixbuild.net
         uses: nixbuild/nixbuild-action@v23
         with:
           nixbuild_token: ${{ secrets.nixbuild_token }}
           oidc: true

       - name: Checkout
         uses: actions/checkout@v4

       - name: Create Checks
         uses: nixbuild/nixbuild-checks@main
   ```

### Configuring Evaluation

All builds that run during a Check Run will run asynchronously on nixbuild.net
and use the full concurrency offered there. However, the evaluation (that
produces .drv-files uploaded to nixbuild.net) runs on your GitHub runner, and
there are some ways you can optimise the evaluation depending on your flake
and the specific runner size you use. The evaluation process works like this:

1. `nixbuild-checks` runs `nix eval` on your Flake to find the outputs to be
   built. You can control this process using the `flake_attr` and `flake_apply`
   inputs, see next section.

2. Now we have a list of flake outputs that we want to build. To compute the
   corresponding `.drv` files for the output, the list is split into chunks
   defined by the `derivations_per_worker` input, and we then start a number
   (defined by the `evaluation_workers` input) of concurrent
   `nix path-info --derivation` processes, each given a chunk of outputs to
   evaluate. As soon as `nix path-info` produces a `.drv` file this is handed
   to the next step.

3. A number (defined by the `upload_workers` input) of concurrent `nix copy`
   processes will copy the `.drv` files to nixbuild.net and then ask
   nixbuild.net to start a build of the derivation. Information about the
   GitHub Check Run name and labels will also be passed along this request.

4. On the nixbuild.net side, a derivation build will be scheduled and the GitHub
   API will be used to create a Check Run. During the derivation build, zero or
   many builds and substitutions will run until the requested derivation has
   been built or failed to build. After that, the GitHub Check Run will be
   updated with the status.

As you can see, we try to run as much as possible in parallel on the GitHub
runner to make up for the fact that Nix evaluation can be slow. All of the
concurrency can be tweaked for your flake and your specific runner instance
(which can have more or less CPUs and memory).

### Configuring Checks

By default, this action will create one Check Run for each check output your
flake exposes. The Check Runs will get names and labels derived from their
system string and attribute name. You can adjust names and labels, but also
filter your flake outputs or switch the top-level attribute used, with the
`flake_attr` and `flake_apply` inputs. These are passed to `nix eval` to
compute what flake outputs should get Check Runs. You can also use this to split
your flake into multiple jobs which sometimes is beneficial for the overall
evaluation time.

Below, we use `flake_apply` to filter for `check` outputs prefixed `builds/`:

```
with:
  flake_attr: 'checks'
  flake_apply: |
    systems: with builtins;
      concatLists (
        attrValues (mapAttrs (system: attrs: concatMap (x:
          let m = match "^builds/(.*)" x; in
          if m == null || m == [] then [] else [{
            attr = "${system}.${x}";
            label = "🚧 ${head m}.${system}";
          }]
        ) (attrNames attrs)) systems)
      )
```

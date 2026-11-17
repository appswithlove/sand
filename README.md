# sand

Self-hosted macOS CI Runners powered by Tart - Apple's Virtualization framework.

## Requirements

- macOS 15+ running on Apple Silicon machines.
- Tart installed and available in PATH
- sand uses tart. it helps understanding tart before using sand (https://tart.run/quick-start/)

## Caveats

macOS DHCP leases last 24 hours by default, causing IP exhaustion if you run more than ~253 VMs per day. To reduce lease time to 10 minutes:

```
sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 600
```

## Install

```
brew trust khoi/sand openai/tools
brew tap khoi/sand
brew tap openai/tools
brew install sand
```

Homebrew only loads formulae from taps you have trusted; the second tap provides Tart.

## Usage

```
sand run --config config.yml
sand destroy --config config.yml
sand run --dry-run --config config.yml
```

## Local test suite

To run the local bash e2e tests (no CI):

```
./Tests/run
```

These tests spin up real VMs and require `tart`, `ssh`, and `sshpass` on your machine. See `Tests/README.md` for environment overrides (image, timeout, SSH creds, etc).

## Start up on boot

Create your config at `~/sand.yml`, then let Homebrew manage a LaunchAgent for it:

```
brew services start sand
```

The service restarts sand if it exits, runs it as an interactive process so launchd doesn't throttle its CPU and I/O (or the VMs it starts), and writes output to `~/Library/Logs/sand.log`. Stop it with `brew services stop sand`.

## Logs

sand logs to macOS default logging system using `os_log`. To see the log

```
log show --predicate "subsystem == \"sand\"" --last 1h --info --debug
log stream --predicate 'subsystem == "sand"' --debug --info --style compact --color always
```

You can also write logs to a file:

```
sand run --config config.yml --log-file /tmp/sand.log
```

## Configuration

Create a `config.yml` and run the CLI with `--config`. 

### VM source

`vm.source` selects the base VM that sand clones for each ephemeral runner.

OCI image pulled from a registry:

```
vm:
  source:
    type: oci
    image: ghcr.io/cirruslabs/macos-runner:tahoe
```

Existing local Tart VM, referenced by name (as shown by `tart list`):

```
vm:
  source:
    type: local
    name: expo-runner
```

For `local` sources sand skips the registry pull and clones the named VM directly (`tart clone <name> <ephemeral>`), so the VM must already exist in `~/.tart/vms`.

### GitHub Actions setup

1) Create a GitHub App and grant `Self-hosted runners` permission set to `Read & Write` at the organization level. https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app
2) Install the app on the organization or the specific repository you want to run against.
3) Download the private key and set `appId`, `organization`, `repository` (optional), and `privateKeyPath` in your config.
4) Optionally set `runnerGroup` to register organization-level runners into a runner group (requires omitting `repository`).
5) Optionally set `serverURL` for GitHub Enterprise (default `https://github.com`). sand derives the REST API URL from it:
   - `https://github.com` → `https://api.github.com`
   - `https://<name>.ghe.com` (Enterprise Cloud with data residency) → `https://api.<name>.ghe.com`
   - any other host (Enterprise Server) → `https://<host>/api/v3`

   Create and install the GitHub App on that instance. The runner tarball still comes from github.com releases.
6) Optionally set `setupCommands`, a list of shell lines that run in the VM after the runner is extracted and before `config.sh`. Each line is a separate SSH command: `cd` or `export` does not carry over to later lines, and a failing line does not stop registration. Quote lines that contain `: `. sand logs each line as written, so do not put secrets in them.

Each VM boot registers the runner as `<runnerName>-<5 hex chars>` so a VM killed mid-session never collides with the next boot's GitHub session. Sand deletes that registration from GitHub when it tears the VM down.

### GitHub Actions runner provisioner
```
runners:
  - name: runner-1
    vm:
      source:
        type: oci
        image: ghcr.io/cirruslabs/macos-runner:tahoe
      cache:
        host: ~/.cache/sand/actions-runner
    provisioner:
      type: github
      config:
        appId: 123456
        organization: my-org
        repository: my-repo
        privateKeyPath: ~/my-app.private-key.pem
        runnerName: runner-1
    healthCheck:
      command: "pgrep -fl /Users/admin/actions-runner/run.sh"
      interval: 30
      delay: 60
```

Sand downloads the Actions runner on the host, checks it against the SHA-256 digest GitHub publishes for the release, and copies the verified tarball into each VM over `scp`. The guest never downloads the runner and never gets write access to the cache, so a job cannot tamper with the runner used by later VMs.

Verified tarballs are kept in `vm.cache.host` (default `~/.cache/sand/actions-runner`), with a `.sha256` file next to each and the three newest versions retained per platform. Sand checks for a new runner release once a day; if GitHub is unreachable it falls back to the newest verified tarball in the cache.

Common pitfalls:
- `vm.cache.host` must be a directory (missing paths are created; file paths are rejected).
- `vm.cache` is ignored unless the provisioner type is `github`.
- `scp` must be available on the host.

GitHub Enterprise Cloud (data residency), repository runner:
```
    provisioner:
      type: github
      config:
        appId: 123456
        organization: my-org
        repository: my-repo
        privateKeyPath: ~/my-app.private-key.pem
        runnerName: runner-1
        serverURL: https://my-enterprise.ghe.com
        setupCommands:
          - sudo xcode-select -s /Applications/Xcode.app
          - "echo 'setup: done'"
```

### Custom provisioner script

```
runners:
  - name: runner-1
    vm:
      source:
        type: oci
        image: "ghcr.io/cirruslabs/ubuntu:latest"
      hardware:
        ramGb: 4
      ssh:
        user: admin
        password: admin
        port: 22
    provisioner:
      type: script
      config:
        run: |
          echo "Hello World" && sleep 10
    healthCheck:
      command: "true"
```

If `healthCheck` is omitted, sand runs `echo healthcheck` every 30s after a 60s delay.

### VM run options

`vm.run` controls how each VM is booted via `tart run`:

```
runners:
  - name: runner-1
    vm:
      run:
        noGraphics: true    # default true; pass --no-graphics
        noClipboard: false  # default false; pass --no-clipboard when true
        nested: false       # default false; pass --nested for nested virtualization
        rootDiskOpts: null  # optional; passed as --root-disk-opts
        netSoftnet: false   # default false; pass --net-softnet
```

Set `nested: true` to boot the VM with `tart run --nested`, enabling nested virtualization inside the guest. This requires an Apple Silicon host and guest that support it (see the [Tart docs](https://tart.run/)).

Set `netSoftnet: true` to boot the VM with `tart run --net-softnet` (Softnet network isolation). Softnet must be installed and set up on the host as the Tart docs describe.

Set `rootDiskOpts` to tune the root disk with `tart run --root-disk-opts`. Since runner VMs are thrown away after each job, `caching=cached,sync=none` trades crash consistency for much faster guest fsync.

### Extra disks

`vm.disks` attaches disk images to each VM with `tart run --disk`. The image stays on the host, so its data outlives the ephemeral VM. Use it for a build cache that needs `mmap`, for example the Xcode compilation cache, which a `vm.mounts` (virtiofs) directory does not support.

```
runners:
  - name: runner-1
    vm:
      disks:
        - path: ~/ci-cache/runner-1-cas.img  # required; ~ is expanded
          mode: rw                            # rw (default) or ro
          sync: none                          # optional; only value: none. Omit for the tart default
```

sand only attaches the disk. Create a raw image on the host before the first run (for example `mkfile -n 50g ~/ci-cache/runner-1-cas.img`). Format it once and mount it in the guest, for example in `preRun`. `sand validate` rejects a path that does not exist, is not a regular file, or contains `:`. It also rejects a path that two runners attach when one of them uses `rw`, because a disk must not be written by two running VMs.

Full configurations keys can be found at [fixtures/sample_full_config.yml](fixtures/sample_full_config.yml) or [fixtures/sample_on_prod.yml](fixtures/sample_on_prod.yml)

## Acknowledgements

- https://github.com/cirruslabs/tart - doing all the heavy lifting interacting with VMs.
- https://github.com/traderepublic/Cilicon - sand is heavily inspired by Cilicon

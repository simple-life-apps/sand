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
brew tap khoi/sand
brew install sand
```

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

Create your config at `~/sand.yml`, then:

```
brew services start sand
```

Logs are written to `~/Library/Logs/sand.log` and `~/Library/Logs/sand.err.log`. Manage the service with:

```
brew services stop sand
brew services restart sand
brew services info sand
```

Note: this runs as a per-user LaunchAgent, which starts at login — enable automatic login on a headless runner so sand starts on machine boot.

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

### GitHub Actions setup

1) Create a GitHub App and grant `Self-hosted runners` permission set to `Read & Write` at the organization level. https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app
2) Install the app on the organization or the specific repository you want to run against.
3) Download the private key and set `appId`, `organization`, `repository` (optional), and `privateKeyPath` in your config.

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
        name: sand-cache
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

To enable runner caching, set `vm.cache`. The GitHub provisioner reuses the Actions runner archive from that mount between restarts; on a cache miss it downloads the tarball and stores it in the mounted directory. On macOS guests, the cache directory resolves to `/Volumes/My Shared Files/<name>` (with `name` acting as the share name).

Sand resolves the latest Actions runner version at runtime via the GitHub API and uses that version for both the download URL and the cache filename. If version resolution fails and a cache directory is available, sand falls back to the newest cached runner tarball it can find.

Common pitfalls:
- `vm.cache.host` must be a directory (missing paths are created; file paths are rejected).
- `vm.cache` is ignored unless the provisioner type is `github`.
- Linux runner cache requires virtiofs support in the guest. The default Ubuntu images from cirruslabs do not provide virtiofs, so cache mounts on Ubuntu are not supported.

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

Full configurations keys can be found at [fixtures/sample_full_config.yml](fixtures/sample_full_config.yml) or [fixtures/sample_on_prod.yml](fixtures/sample_on_prod.yml)

## Acknowledgements

- https://github.com/cirruslabs/tart - doing all the heavy lifting interacting with VMs.
- https://github.com/traderepublic/Cilicon - sand is heavily inspired by Cilicon

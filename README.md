# Evergreen

<img src="docs/assets/evergreen.png" width="104" height="104" alt="">

**Mac app updates, on your terms.** See which apps have updates in one place, install the ones Evergreen supports, and choose when your running apps can restart.

[Website](https://kwonye.github.io/evergreen/) · [Releases](https://github.com/kwonye/evergreen/releases) · [Report an issue](https://github.com/kwonye/evergreen/issues/new)

## Get Evergreen

Evergreen runs on **macOS 14 or later** on Apple silicon and Intel Macs. When a release is available, download its `Evergreen-<version>.zip`, unzip it, and move **Evergreen.app** to **Applications**. If there’s no release ZIP yet, you can [build a local copy](CONTRIBUTING.md#build-and-run).

Open Evergreen to start guided setup. You can revisit it anytime in **Settings → General → Set Up Evergreen**.

## Check and install updates

1. Open **Updates** and choose **Check for Updates**. Checking never closes apps or installs anything.
2. Choose an update to install it, or confirm **Update All…** to install eligible updates one at a time. See the results in **History**, which stays on your Mac.
3. If Evergreen shows **Newer release** or **Check manually**, open the app or its updater to finish. A newer public release doesn’t guarantee it’s available for your copy.

Evergreen can install compatible updates for apps that use Sparkle, Homebrew, Google Chrome’s updater, and Microsoft AutoUpdate. Some apps still need their own updater. Evergreen shows macOS updates and sends you to **System Settings** to install them. For eligible Mac App Store apps, you can opt in to installation in **Settings → Updates**; macOS may ask for administrator approval. Leave Docker Desktop updates off if you can’t interrupt its workloads.

## Choose when apps can restart

- **Protect apps you don’t want interrupted.** Add them to **Whitelist** and Evergreen will skip them, including during **Update All**.
- **Run on your schedule.** Automatic runs are off until you enable them. They cover apps that were running when the job started. Keep Evergreen running in the menu bar, and turn on **Start at Login** in **Settings → General** if you want it to be ready after you sign in. Evergreen won’t wake your Mac or replay missed days.
- **Review what will restart.** Scheduled runs can restart already-up-to-date apps unless you turn that off. Apps without a supported updater are left alone by default; you can opt in to restarting them to activate updates they’ve already downloaded.

Evergreen asks apps to quit normally. It never force-quits, dismisses save dialogs, or reboots your Mac. **Save your work first:** even a normal quit can lose an unsaved form, a private browsing session, or a meeting connection.

## More help

- **Update Evergreen itself:** In a release build, choose **Evergreen → Check for Evergreen Updates…**, or opt in to automatic installation under **Settings → General → Evergreen Updates**.
- **Use a script or an external scheduler, or migrate from Daybreak:** See the [command-line guide](docs/cli.md).
- **Diagnose an update:** See [troubleshooting](docs/troubleshooting.md). When reporting an issue, include your macOS and Evergreen versions and what you saw. Keep private paths and reports out of public issues.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds, code, tests, and release procedures.

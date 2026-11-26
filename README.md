# Evergreen

<img src="docs/assets/evergreen.png" width="104" height="104" alt="">

**Mac app updates, on your terms.** See which apps have updates in one place, install the ones Evergreen supports, and choose when your running apps can restart.

[Website](https://kwonye.github.io/evergreen/) · [Releases](https://github.com/kwonye/evergreen/releases) · [Report an issue](https://github.com/kwonye/evergreen/issues/new)

## Get Evergreen

Evergreen runs on **macOS 14 or later** on Apple silicon and Intel Macs. When a release is available, download its `Evergreen-<version>.zip`, unzip it, and move **Evergreen.app** to **Applications**. If there’s no release ZIP yet, you can [build a local copy](CONTRIBUTING.md#build-and-run).

Open Evergreen to start guided setup. You can revisit it anytime in **Settings → General → Set Up Evergreen**.

## Check and install updates

1. Open **Apps** to check installed apps. Evergreen checks on launch, and **Check for Updates** refreshes the results. Checking never closes apps or installs anything.
2. Choose an update to install it, or confirm **Update All…** to install eligible updates one at a time. See the results in **History**, which stays on your Mac.
3. A **Newer release** with an **Update** button can be installed from Evergreen. Other releases link to the app or its release page.

Evergreen can install compatible Sparkle and Electron releases, including ZIP-only Electron releases, and supports Google Chrome’s updater and Microsoft AutoUpdate. When Homebrew is installed, **Brew** lists updates to formulae and casks. System updates open **System Settings**. For eligible Mac App Store apps, you can opt in to installation in **Settings → Updates**. macOS may ask for administrator approval. Leave Docker Desktop updates off if you can’t interrupt its workloads.

## Choose when apps can restart

- **Protect apps you don’t want interrupted.** Add them to **Whitelist** and Evergreen will skip them, including during **Update All**.
- **Run on your schedule.** In **Settings → Schedule**, enable automatic runs for Apps, Brew, or both. Enable **Run in background when Evergreen is closed** to keep the schedule active while you’re signed in. Evergreen runs within 30 minutes of the scheduled time. After a missed window, it offers **Run Updates Now** when there are updates it can install. Enable **Missed Run Notifications** to use that action from Notification Center.
- **Review what will restart.** Scheduled runs can restart already-up-to-date apps unless you turn that off. Apps without a supported updater are left alone by default; you can opt in to restarting them to activate updates they’ve already downloaded.

Evergreen asks apps to quit normally. It never force-quits, dismisses save dialogs, or reboots your Mac. **Save your work first:** even a normal quit can lose an unsaved form, a private browsing session, or a meeting connection.

## More help

- **Update Evergreen itself:** In a release build, choose **Evergreen → Check for Evergreen Updates…**, or opt in to automatic installation under **Settings → General → Evergreen Updates**.
- **Use a script or an external scheduler, or migrate from Daybreak:** See the [command-line guide](docs/cli.md).
- **Diagnose an update:** See [troubleshooting](docs/troubleshooting.md). When reporting an issue, include your macOS and Evergreen versions and what you saw. Keep private paths and reports out of public issues.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds, code, tests, and release procedures.

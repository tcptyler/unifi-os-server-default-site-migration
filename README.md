# unifi-os-server-default-site-migration

Make an imported site the **default** site on a self-hosted **UniFi OS Server** (Linux). The script removes the old empty "Default" site, so your site is the only one left.

> [!WARNING]
> This script edits the UniFi Network database directly. That is **not supported by Ubiquiti**, may break with future updates, and is used **at your own risk**.

## Why

When you move a site to a new UniFi OS Server with **Export Site** / **Import Site**, the new server ends up with two sites: its own **Default** plus your imported site. The Default site cannot be deleted from the UI, and there is no supported way to make a different site the default. This script does both for you.

## Before you start

- UniFi OS Server installed on Linux with the official installer.
- Your site is already imported: enable **Multi-Site Management** (**Settings > System > Site Management**), then site switcher > **Import Site**.
- An SSH session on the server as a user with `sudo`.
- Best on a fresh UniFi OS Server install that holds only the Default site and your imported site.

## How to use

Run this in an SSH session on the server. It downloads the script and runs it without saving it:

```
bash <(curl -fsSL https://raw.githubusercontent.com/tcptyler/unifi-os-server-default-site-migration/main/unifi-os-server-default-site-migration.sh)
```

Run it as your normal user, not with `sudo` in front. The script asks for your `sudo` password itself. Then answer the prompts.

**Or copy and paste:** open [`unifi-os-server-default-site-migration.sh`](unifi-os-server-default-site-migration.sh), copy **all** of it, from the first line (`bash <<'UOS_EOF'`) to the last line (`UOS_EOF`), and paste it into your SSH session. You can also save the file on the server and run `bash unifi-os-server-default-site-migration.sh`.

## What it does

1. **Finds everything on its own:** the UniFi OS Server service, the account that runs its containers, the container, the Mongo client, and the UniFi Network database and port.
2. **Lists your sites.** The hidden system site is not shown. The current Default is shown greyed out and cannot be picked. You pick your site by number and confirm.
3. **Moves the default flags** from the old Default site to your site, checks the result, then restarts UniFi OS Server.
4. **Deletes the old Default site** and its configuration: settings, networks, WiFi networks and groups, user groups, RADIUS profiles, DPI groups and admin privileges for that site.
5. **Renames your site's internal name** to `default`.
6. **Turns off Multi-Site Management** if your site is now the only one.
7. **Restarts UniFi OS Server** again.
8. **Asks you to confirm** that you see only your site in the UI. If you don't, it checks the service and the database and tells you what is different.

If no site besides Default is found, the script asks whether you imported it. If you did, it checks again and searches the other databases. If you didn't, it tells you to import it and rerun the script.

## Good to know

- Each restart restarts **every** application on the UniFi OS Server, not only UniFi Network.
- Every change to a site must affect exactly one site, or the script stops and says which step failed.
- The hidden system site (`super`) is never changed.
- The old Default is removed the same way a delete in the UniFi UI removes a site. Like the UI, it leaves history (activity log, alerts, topology snapshot) and a few records the UI also keeps (the "All APs" group and the site's generated SSL certificate). Unlike the UI, it does not add "removed" entries to the activity log.
- After the script finishes, move your devices from the old server (Export Site wizard > device migration step) and take a fresh backup.

## Tested on

UniFi OS Server 5.1.42 (linux-arm64), official installer, on Ubuntu 26.04.1 LTS, with a site imported from another server. Windows and macOS installs are not supported.

## Credits

Method from the Ubiquiti Community Wiki guide [Changing the Default Site in UniFi](https://ubntwiki.com/guides/changing_the_default_site_in_unifi), which credits @ckd in the unofficial Ubiquiti Discord.

Not affiliated with or endorsed by Ubiquiti Inc. UniFi is a trademark of Ubiquiti Inc.

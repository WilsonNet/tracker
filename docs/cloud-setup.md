# Google Drive setup

Tracker can back up a self-contained project folder to a visible folder in
your Google Drive and restore it on another computer. It does not sync a
live session; you choose when to **BACK UP NOW** or **RESTORE**.

## What Tracker can see

Tracker requests exactly one OAuth scope:

```text
https://www.googleapis.com/auth/drive.file
```

`drive.file` only grants access to files and folders **created by Tracker**.
It cannot read, modify, or delete unrelated Drive files. Tracker also puts a
private `appProperties` marker (`tracker=1`) on everything it creates and
filters every lookup and restore by that marker. Even if a same-named file
appears inside the Tracker folder, the app won’t see or overwrite it.

The client contains **no remote delete operation**. Deleting the folder in
Google Drive is the deletion path.

## One-time Google Cloud setup

You only create the OAuth client once. The same Client ID/secret works on
every computer.

1. Open <https://console.cloud.google.com/> with the Google account whose
   Drive you use. Create a project named `Tracker` (no organization needed).
2. **APIs & Services → Library** → search **Google Drive API** → **Enable**.
   No billing account is required for normal personal use.
3. **APIs & Services → OAuth consent screen** (or **Google Auth Platform**):
   - User type: **External** (use **Internal** for Google Workspace).
   - App name: `Tracker`.
   - Support/developer contact: your email.
   - **Data access / Scopes** → add exactly:
     `https://www.googleapis.com/auth/drive.file`
   - **Audience / Test users** → add every Google account you will use.
   - Leave it in **Testing** for personal use.
4. **Credentials → Create credentials → OAuth client ID**:
   - Application type: **Desktop app**
   - Name: `Tracker Desktop`
   - Create.
5. Copy the **Client ID** and **Client secret**.
6. In Tracker: **Settings → CLOUD**:
   - Drive folder: `Tracker` (or any name you want in My Drive).
   - Client ID / Client secret.
   - `CONNECT`; approve the browser consent page.
   - If Google says the app is unverified, choose **Advanced → Go to Tracker**
     (expected for a personal/testing OAuth client).
7. On another computer, use the same Client ID/secret and account. Do not copy
   `cloud.json`; authorize each machine.

## Testing vs production

While the OAuth consent screen is in **Testing**, Google expires refresh
tokens after **7 days**. You do **not** re-add test users; just click
`CONNECT` again and approve. Each computer re-authorizes
separately.

To avoid the weekly re-login, **Publish app** in the OAuth consent screen.
Production refresh tokens do not have the 7-day testing expiry. Google may
show an unverified-app warning or require verification for wider use. An
Internal app in Google Workspace also avoids the 7-day expiry.

## Where files live

```text
My Drive/
  Tracker/                    <- configurable in Settings
    index.json                <- catalog of projects
    projects/
      My-Song-a1b2c3/         <- name + short cloud id
        project.json
        track1.wav ... trackN.wav   (N = the project's track count, up to 24)
        take files
        bounce.wav
        .tracker-cloud-id
```

The folder is visible in Drive. You can browse it, rename it, or delete it
without Tracker installed. If you rename the **root** folder, update the
**Drive folder** setting to match; otherwise Tracker creates a new folder on
the next backup. Renaming an individual project folder is safe because the
index stores its folder ID.

Deleting a project in Tracker does not delete cloud data. Delete the folder in
Drive when you want it gone. Revoke access at
<https://myaccount.google.com/permissions> or
<https://drive.google.com/drive/settings> → **Manage apps**.

## Resume on another computer

1. Install Tracker on the new machine. You do **not** need the old project
   folder or `cloud.json`.
2. Open **Settings → CLOUD**, enter the same Client ID/secret and Drive folder
   name, then `CONNECT` and approve the browser consent.
3. Press `g` to open **Cloud projects**. Pick the project and press `Enter`.
4. Tracker restores it into a fresh folder next to the current project folder:
   the parent of `~/.local/share/tracker/session` by default, or the parent of
   whatever project folder is configured in Settings. The folder is named
   `<project name>-<short cloud id>`, e.g.
   `~/.local/share/tracker/My-Song-a1b2c3`.
5. If that folder already exists, Tracker uses `-2`, `-3`, … and leaves the
   existing folder untouched. Restore never overwrites an existing project.
6. The restored project opens automatically. Press `PLAY` to audition it, or
   `R` to continue recording. New takes are written into the restored folder.
7. The restored folder does not contain `cloud.json`; credentials stay
   machine-local. The next `u`/BACK UP NOW updates the same cloud project using
   the restored `.tracker-cloud-id`.

If the project has no `.tracker-cloud-id` (for example, an older copy), the
first backup creates a new cloud identity and therefore a separate Drive
project. Keep the restored folder together when moving a project by hand.

Starting a **new** local project with the same display name as an existing
cloud project is safe: it has a new `.tracker-cloud-id`, so it gets its own
`projects/<name>-<short id>` folder and its own index entry. Both projects
appear in `g`, and restoring one never overwrites the other locally. Copying a
project folder **with** its `.tracker-cloud-id` is different: that folder is the
same cloud identity, so `BACK UP NOW` updates the existing cloud project
instead of creating a second one.

## Local token storage

`~/.config/tracker/cloud.json` (or `$XDG_CONFIG_HOME/tracker/cloud.json`) holds
the Client ID/secret, refresh token, and folder name. It is written with
`0600` permissions. It contains no Drive file contents. With an explicit
`--session DIR`, Tracker keeps `cloud.json` inside `DIR` so isolated test and
throwaway runs never touch the real machine config.

## Safety properties (enforced in code and tests)

- OAuth `drive.file` scope, not full Drive.
- Every created file/folder carries the `tracker=1` app marker.
- Every list/query is anchored to the Tracker root or one project folder.
- Restore accepts only ordinary filenames; `..`, `/`, `\`, NUL, and empty
  names are rejected.
- Restore never reuses or removes an existing local folder; downloads go into
  a freshly generated `.partial-*` sibling and move into place only on success.
- There is no Google Drive DELETE request in the client.
- The fake-Drive integration test seeds an unrelated same-named file in the
  project folder, runs two backups and a restore, and asserts the innocent
  file is byte-identical, not downloaded, and `deletes == 0`.

## Troubleshooting

- **`redirect_uri_mismatch`**: use a **Desktop app** OAuth client, not a Web
  application client. Do not register the loopback port; Google allows it for
  desktop clients.
- **`invalid_grant` / “session expired”**: the Testing-mode refresh token
  expired. Click `CONNECT` again.
- **Scope mismatch**: the consent screen must include `drive.file`; remove an
  old `drive.appdata` grant and reconnect if you changed scopes.
- **Two `Tracker` folders**: an unrelated folder with the same name already
  exists. `drive.file` cannot see it, so Tracker creates its own. Rename the
  configured folder or delete the unused one in Drive.
- **Paste does nothing**: Tracker falls back to `wl-paste`/`xclip` when SDL
  cannot read the clipboard; ensure one is installed.
- **No browser opens**: install `xdg-open` (or `gio`) and retry.

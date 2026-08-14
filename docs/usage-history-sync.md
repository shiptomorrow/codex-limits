# Shared usage history

## Scope

Shared usage history is optional and contains only main-limit usage samples. A usage sample consists of its locally recorded observation time, remaining percentage, and the window reset returned by Codex. Preferences, launch settings, credentials, raw Codex responses, and other device state never sync.

One sync folder represents one Codex account. The app does not identify or verify the account, so the settings interface tells the user to use the folder only on Macs signed in to the same Codex account. The folder must be private and not shared with other people. Files remain readable JSON without app-level encryption and contain no credentials or Codex content.

## Behavior

- Choosing a sync folder enables synchronization. The app accepts an empty folder that it can initialize or a folder with a supported Codex Limits format marker; it rejects other nonempty folders.
- On first connection, the app merges the existing local 90-day history with the history already in the folder without replacing either side.
- Sync runs on launch and at most once every ten minutes while usage checks continue in the background.
- Each Mac imports available history independently during those refreshes. The app does not track whether another Mac has downloaded a change.
- Reading current usage from Codex and exchanging folder history are independent operations. Failure of either one does not prevent the other result from updating the app.
- Stopping sync disconnects the folder without deleting local or folder history.
- A missing folder or malformed history file never replaces valid local history or interrupts the main usage display. The app retries later and reports the problem only in settings.
- Valid files continue to merge when one history file is malformed. An unsupported folder version prevents all writes.

## Storage and merge rules

- Local history and its optional folder replica use the same versioned daily JSON format.
- Each installation has a random local identifier and writes only files belonging to that identifier.
- Usage history is event-based: a new sample is written only when its remaining percentage differs from the latest stored sample. Observation time and window reset are retained for every actual percentage change.
- Existing daily files are compacted automatically and idempotently on load. Consecutive samples with the same remaining percentage are reduced to the first sample in that run, including runs spanning daily-file boundaries.
- A daily file larger than 1 MB is skipped and reported like any other unreadable history file.
- Samples older than 90 days are ignored. An installation removes only its own expired daily files and never deletes another installation's files.
- iCloud Drive access uses coordinated file operations. No SQLite database file is synchronized.

Existing usage samples are migrated automatically from `UserDefaults` on the first launch that uses file-backed history. Migration is idempotent and keeps the legacy state available until the new daily files have been written and read successfully. After successful migration, usage history is removed from `UserDefaults`, which retains only small preferences and identifiers.

## Settings

The settings interface uses a `History sync` section with this description:

> Keep usage history in a folder available on your other Macs.

`Choose Folder…` selects and connects a folder. When connected, the section shows the folder name and `Stop Syncing`; it shows a short status only when there is a problem. There is no separate toggle, folder-opening action, sync-now action, last-sync timestamp, or claim that another Mac is up to date. Usage refreshes pick up sync work when the ten-minute maintenance interval is due.

The account invariant is presented as:

> Use this folder only on Macs signed in to the same Codex account.

Folder privacy is presented as:

> Choose a private folder that isn’t shared with other people.

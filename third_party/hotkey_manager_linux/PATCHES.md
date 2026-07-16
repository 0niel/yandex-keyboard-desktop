# Local hardening patch

This directory is the MIT-licensed `hotkey_manager_linux` 0.2.0 package from
the upstream `leanflutter/hotkey_manager` repository.

The local patch is intentionally narrow:

- propagate `keybinder_bind()` rejection as a platform error;
- add idempotent, initialized unregister behavior;
- reject duplicate identifiers;
- ignore unmatched native callbacks instead of using uninitialized pointers;
- unbind tracked shortcuts during plugin disposal; and
- release temporary GTK/Flutter values; and
- transfer nested event values exactly once to prevent callback double-free.

The package remains pinned until the in-tree Wayland GlobalShortcuts portal
backend replaces Keybinder. Rebase or removal must preserve the registration
failure and cleanup tests in the application.

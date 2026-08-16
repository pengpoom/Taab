# Dock click decision

Glide only consumes a Dock click when it has both a running application and a concrete tracked window to operate on.

- A non-frontmost application focuses or restores its most recently focused window.
- A frontmost application minimizes its focused window.
- If the chosen window is already minimized, the click restores it instead of minimizing another window.
- An unlaunched application, a folder/stack, or an application without a tracked actionable window keeps the native Dock behavior.

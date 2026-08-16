# Per-display sidebar layout

Each connected display owns one independent placement value: `off`, `left`, or `right`.

- Placement is stored under the display UUID, not under the display index or one global preference.
- A panel stays inside that display's visible frame with an eight-point edge margin.
- The main display defaults to the right; additional displays default to the left until the user chooses otherwise.
- Disconnecting a display removes its panel but keeps its saved placement for the next connection.

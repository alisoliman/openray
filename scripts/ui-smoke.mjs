// Run in Codex's node_repl with the Computer Use skill and a freshly launched app.
// The app must have an empty search field. This deliberately does NOT click it.
export async function verifyInitialSearchFocus(sky, app = "com.alisoliman.openray") {
  await sky.get_app_state({ app });
  await sky.type_text({ app, text: "6 * 7" });
  const state = await sky.get_app_state({ app, disableDiff: true });
  if (!state.text.includes("Value: 6 * 7") || !state.text.includes("42, Calculator")) {
    throw new Error("Initial keyboard focus failed: typing did not produce the calculator result.");
  }
  return state;
}

export async function verifyEditorFocusRestoration(sky, app = "com.alisoliman.openray") {
  await sky.type_text({ app, text: "Verification" });
  const state = await sky.get_app_state({ app, disableDiff: true });
  if (!state.text.includes("Value: Verification")) {
    throw new Error("Search did not regain keyboard focus after the editor sheet closed.");
  }
  return state;
}

// Call from inside a library feature. No settling delay is allowed between Back and typing.
export async function verifyRapidBackTyping(sky, app = "com.alisoliman.openray") {
  await sky.press_key({ app, key: "Escape" });
  await sky.type_text({ app, text: "search notes" });
  const state = await sky.get_app_state({ app, disableDiff: true });
  if (!state.text.includes("Value: search notes")) {
    throw new Error("Rapid input after Back lost characters.");
  }
  return state;
}

// Supply a descriptor reader for the dedicated private verification pasteboard.
// Run after an image fixture has been captured, without typing in search first.
export async function verifyEmptyClipboardImageCopy(sky, app, describePasteboard) {
  const before = await sky.get_app_state({ app, disableDiff: true });
  const search = before.text.split("\n").find((line) => line.includes("ID: launcher.search"));
  if (!search || search.includes("Value:") || !before.text.includes("Image ·")) {
    throw new Error("Expected an image result and an empty clipboard query.");
  }
  await sky.press_key({ app, key: "Return" });
  const after = await sky.get_app_state({ app, disableDiff: true });
  const clipboard = await describePasteboard();
  if (!after.text.includes("Copied to clipboard") || !clipboard.pngBytes ||
      !clipboard.types.includes("com.openray.generated")) {
    throw new Error("Return did not copy the selected image in its native format.");
  }
  return after;
}
